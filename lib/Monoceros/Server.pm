package Monoceros::Server;

use strict;
use warnings;
use base qw/Plack::Handler::Starlet/;
use IO::Socket;
use IO::Select;
use IO::FDPass;
use Parallel::Prefork;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Util qw(fh_nonblocking);
use Digest::MD5 qw/md5_hex/;
use Time::HiRes qw/time/;
use Carp ();
use Plack::Util;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK :sys_wait_h);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use List::Util qw/shuffle first/;

use constant WRITER => 0;
use constant READER => 1;

use constant S_SOCK => 0;
use constant S_TIME => 1;
use constant S_REQS => 2;
use constant S_IDLE => 3;

use constant KEEP_CONNECTION => 0;
use constant CLOSE_CONNECTION => 1;

sub new {
    my $class = shift;
    my %args = @_;

    # setup before instantiation
    my $listen_sock;
    if (defined $ENV{SERVER_STARTER_PORT}) {
        my ($hostport, $fd) = %{Server::Starter::server_ports()};
        if ($hostport =~ /(.*):(\d+)/) {
            $args{host} = $1;
            $args{port} = $2;
        } else {
            $args{port} = $hostport;
        }
        $listen_sock = IO::Socket::INET->new(
            Proto => 'tcp',
        ) or die "failed to create socket:$!";
        $listen_sock->fdopen($fd, 'w')
            or die "failed to bind to listening socket:$!";
    }
    my $max_workers = 5;
    for (qw(max_workers workers)) {
        $max_workers = delete $args{$_}
            if defined $args{$_};
    }

    my $self = bless {
        host                 => $args{host} || 0,
        port                 => $args{port} || 8080,
        max_workers          => $max_workers,
        timeout              => $args{timeout} || 300,
        keepalive_timeout    => $args{keepalive_timeout} || 10,
        max_keepalive_reqs   => $args{max_keepalive_reqs} || 100,
        server_software      => $args{server_software} || $class,
        server_ready         => $args{server_ready} || sub {},
        min_reqs_per_child   => (
            defined $args{min_reqs_per_child}
                ? $args{min_reqs_per_child} : undef,
        ),
        max_reqs_per_child   => (
            $args{max_reqs_per_child} || $args{max_requests} || 100,
        ),
        err_respawn_interval => (
            defined $args{err_respawn_interval}
                ? $args{err_respawn_interval} : undef,
        ),
        _using_defer_accept  => undef,
        listen_sock => ( defined $listen_sock ? $listen_sock : undef),
    }, $class;

    $self;
}

sub run {
    my ($self, $app) = @_;
    $self->setup_listener();
    $self->setup_sockpair();
    $self->run_workers($app);
}

sub setup_sockpair {
    my $self = shift;
    my @worker_pipe = IO::Socket->socketpair(AF_UNIX, SOCK_STREAM, 0)
        or die "failed to create socketpair: $!";
    $self->{worker_pipe} = \@worker_pipe; 

    my @lstn_pipes;
    for (0..1) {
        my @pipe_lstn = IO::Socket->socketpair(AF_UNIX, SOCK_STREAM, 0)
            or die "failed to create socketpair: $!";
        push @lstn_pipes, \@pipe_lstn;
    }
    $self->{lstn_pipes} = \@lstn_pipes;

    1;
}

sub run_workers {
    my ($self,$app) = @_;
    local $SIG{PIPE} = 'IGNORE';    
    my $pid = fork;  
    my $blocker;
    if ( $pid ) {
        #parent
        $blocker = $self->connection_manager($pid);
    }
    elsif ( defined $pid ) {
        $self->request_worker($app);
    }
    else {
        die "failed fork:$!";
    }

    while (1) { 
        my $kid = waitpid(-1, WNOHANG);
        last if $kid < 1;
    }
    undef $blocker;
}

sub queued_fdsend {
    my $self = shift;
    my $info = shift;

    my $pipe_n = KEEP_CONNECTION;
    if ( $info->[S_REQS] + 1 >= $self->{max_keepalive_reqs} ) {
        $pipe_n = CLOSE_CONNECTION;
    }
    my $queue = "fdsend_queue_$pipe_n";
    my $worker = "fdsend_worker_$pipe_n";

    $info->[S_IDLE] = 0; #no-idle

    $self->{$queue} ||= [];
    push @{$self->{$queue}},  $info;
    $self->{$worker} ||= AE::io $self->{lstn_pipes}[$pipe_n][WRITER], 1, sub {
        do {
            if ( !$self->{$queue}[0][S_SOCK] ) {
                shift @{$self->{$queue}};
                return;
            }
            if ( ! IO::FDPass::send(fileno $self->{lstn_pipes}[$pipe_n][WRITER], fileno $self->{$queue}[0][S_SOCK] ) ) {
                return if $! == Errno::EAGAIN || $! == Errno::EWOULDBLOCK;
                undef $self->{$worker};
                die "unable to pass file handle: $!"; 
            }
            shift @{$self->{$queue}};
        } while @{$self->{$queue}};
        undef $self->{$worker};
    };

    1;
}

sub connection_manager {
    my ($self, $worker_pid) = @_;

    for (0..1) {
        $self->{lstn_pipes}[$_][READER]->close;
        fh_nonblocking $self->{lstn_pipes}[$_][WRITER], 1;
    }
    $self->{worker_pipe}->[WRITER]->close;    
    fh_nonblocking $self->{worker_pipe}->[READER], 1;
    fh_nonblocking $self->{listen_sock}, 1;

    my %manager;
    my %sockets;
    my $term_received = 0;
    my %wait_read;

    my $cv = AE::cv;
    my $sig;$sig = AE::signal 'TERM', sub {
        delete $self->{listen_sock}; #stop new accept
        $term_received++;
        my $t;$t = AE::timer 0, 0.1, sub {
            return if keys %sockets;
            kill 'TERM', $worker_pid;
            undef $t;
            $cv->send;
        };
    };

    $manager{disconnect_keepalive_timeout} = AE::timer 0, 1, sub {
        my $time = time;
        for my $key ( keys %sockets ) {
            if ( $sockets{$key}->[S_IDLE] && $time - $sockets{$key}->[1] > $self->{timeout} ) { #idle && timeout
                delete $wait_read{$key};
                delete $sockets{$key};
            }
            if ( !$sockets{$key}->[S_IDLE] && $time - $sockets{$key}->[1] > $self->{keepalive_timeout} ) {
                # not idle && timeout
                if ( ! $sockets{$key}->[S_SOCK]->connected() ) {
                    delete $wait_read{$key};
                    delete $sockets{$key};
                }
            }
        }
    };
    
    $manager{main_listener} = AE::io $self->{listen_sock}, 0, sub {
        return unless $self->{listen_sock};
        my ($fh,$peer) = $self->{listen_sock}->accept;
        return unless $fh;
        my $remote = md5_hex($peer);
        $sockets{$remote} = [$fh,time,0,1];  #fh,time,reqs,idle
        fh_nonblocking $fh, 1
            or die "failed to set socket to nonblocking mode:$!";
        setsockopt($fh, IPPROTO_TCP, TCP_NODELAY, 1)
            or die "setsockopt(TCP_NODELAY) failed:$!";
        if ( $self->{_using_defer_accept} ) {
            $self->queued_fdsend($sockets{$remote});
        }
        else {
            $wait_read{$remote} = AE::io $fh, 0, sub {
                $self->queued_fdsend($sockets{$remote});
                undef $wait_read{$remote};
            };
        }
    };

    $manager{worker_listener} =  AnyEvent::Handle->new(
        fh => $self->{worker_pipe}->[READER],
        on_read => sub {
            my $handle = shift;
            $handle->push_read( chunk => 36, sub {
                my ($method,$remote) = split / /, $_[1], 2;
                return unless exists $sockets{$remote};
                if ( $method eq 'end' ) {
                    $sockets{$remote}->[S_IDLE] = 1; #idle
                    delete $sockets{$remote};
                } elsif ( $method eq 'kep' ) {
                    $sockets{$remote}->[S_TIME] = time; #time
                    $sockets{$remote}->[S_REQS]++; #reqs
                    $sockets{$remote}->[S_IDLE] = 1; #idle
                    $wait_read{$remote} = AE::io $sockets{$remote}->[S_SOCK], 0, sub {
                        $self->queued_fdsend($sockets{$remote});
                        undef $wait_read{$remote};
                    };
                }
            });
        },
    );

    $cv->recv;
    \%manager;
}

sub request_worker {
    my ($self,$app) = @_;

    $self->{listen_sock}->close;
    $self->{worker_pipe}->[READER]->close;

    for (0..1) {
        $self->{lstn_pipes}[$_][WRITER]->close;
        $self->{lstn_pipes}[$_][READER]->blocking(0);
    }

    # use Parallel::Prefork
    my %pm_args = (
        max_workers => $self->{max_workers},
        trap_signals => {
            TERM => 'TERM',
            HUP  => 'TERM',
        },
    );
    if (defined $self->{err_respawn_interval}) {
        $pm_args{err_respawn_interval} = $self->{err_respawn_interval};
    }

    my $pm = Parallel::Prefork->new(\%pm_args);

    while ($pm->signal_received !~ /^(TERM)$/) {
        $pm->start(sub {
            my $select_lstn_pipes = IO::Select->new();
            for (0..1) {
                $select_lstn_pipes->add($self->{lstn_pipes}[$_][READER]);
            }

            my $max_reqs_per_child = $self->_calc_reqs_per_child();
            my $proc_req_count = 0;
            $self->{can_exit} = 1;
            
            local $SIG{TERM} = sub {
                exit 0 if $self->{can_exit};
                $self->{term_received}++;
                exit 0 if  $self->{term_received} > 1;
                
            };
            local $SIG{PIPE} = 'IGNORE';
             
            while ( $proc_req_count < $max_reqs_per_child ) {
                my @can_read = $select_lstn_pipes->can_read(1);
                if ( !@can_read ) {
                    next;
                }
                my $fd;
                my $pipe_n;
                for my $pipe_read ( @can_read ) {
                    my $fd_recv = IO::FDPass::recv($pipe_read->fileno);
                    if ( $fd_recv >= 0 ) {
                        $fd = $fd_recv;
                        $pipe_n = first { $pipe_read eq $self->{lstn_pipes}[$_][READER] } qw(0 1);
                        last;
                    }
                    next if $! == Errno::EAGAIN || $! == Errno::EWOULDBLOCK;
                    #die "couldnot read pipe: $!";
                }

                next unless defined $fd;
                ++$proc_req_count;
                my $conn = IO::Socket::INET->new_from_fd($fd,'r+')
                    or die "unable to convert file descriptor to handle: $!";
                my $peername = $conn->peername;
                next unless $peername; #??
                my ($peerport,$peerhost) = unpack_sockaddr_in $peername;
                my $remote = md5_hex($peername);

                my $env = {
                    SERVER_PORT => $self->{port},
                    SERVER_NAME => $self->{host},
                    SCRIPT_NAME => '',
                    REMOTE_ADDR => inet_ntoa($peerhost),
                    REMOTE_PORT => $peerport,
                    'psgi.version' => [ 1, 1 ],
                    'psgi.errors'  => *STDERR,
                    'psgi.url_scheme' => 'http',
                    'psgi.run_once'     => Plack::Util::FALSE,
                    'psgi.multithread'  => Plack::Util::FALSE,
                    'psgi.multiprocess' => Plack::Util::TRUE,
                    'psgi.streaming'    => Plack::Util::TRUE,
                    'psgi.nonblocking'  => Plack::Util::FALSE,
                    'psgix.input.buffered' => Plack::Util::TRUE,
                    'psgix.io'          => $conn,
                };
                $self->{_is_deferred_accept} = 1; #ready to read
                my $is_keepalive = 1; # to use "keepalive_timeout" in handle_connection, 
                                      #  treat every connection as keepalive 
                my $keepalive = $self->handle_connection($env, $conn, $app, $pipe_n != CLOSE_CONNECTION, $is_keepalive);
                
                my $method = 'end';
                if ( !$self->{term_received} && $keepalive ) {
                    $method = 'kep';
                }
                $self->{worker_pipe}->[WRITER]->syswrite("$method $remote");
            }
        });
    }
    $pm->wait_all_children;
    exit;
}


1;