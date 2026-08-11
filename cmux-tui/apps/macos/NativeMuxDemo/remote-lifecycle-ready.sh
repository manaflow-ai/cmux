#!/usr/bin/env bash

# Run one remote-demo launcher and publish its ordered lifecycle protocol. The
# caller gives the supervisor the only output writer. The launcher publishes
# progress to progress_pipe, which is private to the supervisor. This lets one
# process own child identity, phase deadlines, cancellation, and terminal exit.
cmux_supervise_remote_demo() {
  local output_fd="$1"
  local progress_pipe="$2"
  local transfer_timeout="$3"
  local startup_timeout="$4"
  local exit_timeout="$5"
  shift 5
  [[ "${1:-}" == "--" ]] || return 2
  [[ "$output_fd" =~ ^[0-9]+$ ]] || return 2
  shift
  (( $# > 0 )) || return 2

  exec 5<&-
  exec /usr/bin/perl - "$output_fd" "$progress_pipe" \
    "$transfer_timeout" "$startup_timeout" "$exit_timeout" "$@" <<'PERL'
use strict;
use warnings;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK O_RDWR);
use IO::Handle;
use IO::Select;
use POSIX qw(WNOHANG setsid);
use Time::HiRes qw(CLOCK_MONOTONIC clock_gettime);

my ($output_fd, $progress_path, $transfer_timeout, $startup_timeout,
    $exit_timeout, @command) = @ARGV;
@command or exit 2;

open(my $output, ">&=$output_fd") or die "open output fd $output_fd: $!";
$output->autoflush(1);
sysopen(my $progress, $progress_path, O_RDWR | O_NONBLOCK)
    or die "open $progress_path: $!";
pipe(my $signals, my $signal_writer) or die "pipe: $!";
pipe(my $group_ready, my $group_ready_writer) or die "pipe: $!";
for my $handle ($signals, $signal_writer) {
    my $flags = fcntl($handle, F_GETFL, 0);
    defined($flags) or die "fcntl get: $!";
    fcntl($handle, F_SETFL, $flags | O_NONBLOCK) or die "fcntl set: $!";
}

my $child_pid;
my $signal = sub {
    my ($byte) = @_;
    return sub { syswrite($signal_writer, $byte); };
};
$SIG{CHLD} = $signal->("C");
$SIG{USR1} = $signal->("K");
$SIG{USR2} = $signal->("D");
$SIG{INT} = $signal->("T");
$SIG{TERM} = $signal->("T");
$SIG{HUP} = $signal->("T");
$SIG{PIPE} = "IGNORE";

$child_pid = fork();
defined($child_pid) or die "fork: $!";
if ($child_pid == 0) {
    close($output);
    close($progress);
    close($signals);
    close($signal_writer);
    close($group_ready);
    setsid() >= 0 or exit 126;
    syswrite($group_ready_writer, "R") == 1 or exit 126;
    close($group_ready_writer);
    exec { $command[0] } @command;
    exit 127;
}
close($group_ready_writer);
my $group_ready_byte = "";
my $group_ready_count = sysread($group_ready, $group_ready_byte, 1);
close($group_ready);
if (!defined($group_ready_count) || $group_ready_count != 1
    || $group_ready_byte ne "R") {
    waitpid($child_pid, 0);
    my $setup_status = ($? & 127) ? 128 + ($? & 127) : ($? >> 8);
    print {$output} "owner-started\nlauncher-exited $setup_status\n";
    exit($setup_status);
}

my $phase = "transfer";
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $transfer_timeout;
my $child_status;
my $progress_buffer = "";
my $output_open = 1;
my $select = IO::Select->new($progress, $signals);

sub publish {
    my ($event) = @_;
    return 0 unless $output_open;
    if (!print {$output} "$event\n") {
        $output_open = 0;
        close($output);
        begin_termination("TERM");
        return 0;
    }
    return 1;
}

sub begin_termination {
    my ($signal_name) = @_;
    return unless defined($child_pid);
    kill($signal_name, -$child_pid);
    return if $phase eq "reap";
    $phase = "exit";
    $deadline = clock_gettime(CLOCK_MONOTONIC) + $exit_timeout;
}

sub handle_progress {
    my ($event) = @_;
    if ($event eq "daemon-starting" && $phase eq "transfer") {
        $phase = "startup";
        $deadline = clock_gettime(CLOCK_MONOTONIC) + $startup_timeout;
    } elsif ($event eq "ready" && $phase eq "startup") {
        $phase = "running";
        undef($deadline);
    }
    publish($event);
}

sub drain_progress {
    while (1) {
        my $chunk = "";
        my $count = sysread($progress, $chunk, 4096);
        last if !defined($count);
        last if $count == 0;
        $progress_buffer .= $chunk;
        while ($progress_buffer =~ s/\A([^\n]*)\n//) {
            handle_progress($1);
        }
    }
}

sub reap_child {
    return 0 unless defined($child_pid);
    my $waited = waitpid($child_pid, WNOHANG);
    return 0 if $waited <= 0;
    drain_progress();
    my $wait_status = $?;
    $child_status = ($wait_status & 127)
        ? 128 + ($wait_status & 127)
        : ($wait_status >> 8);
    kill("KILL", -$child_pid);
    undef($child_pid);
    publish("launcher-exited $child_status");
    return 1;
}

publish("owner-started");
while (1) {
    my $remaining;
    if (defined($deadline)) {
        $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
        $remaining = 0 if $remaining < 0;
    }
    my @ready = $select->can_read($remaining);
    if (!@ready) {
        next if !defined($deadline)
            || clock_gettime(CLOCK_MONOTONIC) < $deadline;
        if ($phase eq "transfer") {
            publish("transfer-timeout");
            begin_termination("TERM");
        } elsif ($phase eq "startup") {
            publish("startup-timeout");
            begin_termination("TERM");
        } elsif ($phase eq "exit") {
            publish("exit-timeout");
            kill("KILL", -$child_pid) if defined($child_pid);
            $phase = "reap";
            $deadline = clock_gettime(CLOCK_MONOTONIC) + $exit_timeout;
        } elsif ($phase eq "reap") {
            publish("launcher-exited 124");
            exit 124;
        }
        next;
    }

    # Progress is drained before SIGCHLD so cleanup events always precede the
    # terminal launcher-exited event.
    if (grep { fileno($_) == fileno($progress) } @ready) {
        drain_progress();
    }
    if (grep { fileno($_) == fileno($signals) } @ready) {
        my $bytes = "";
        sysread($signals, $bytes, 4096);
        for my $byte (split(//, $bytes)) {
            if ($byte eq "K") {
                begin_termination("KILL");
            } elsif ($byte eq "D" && $phase eq "running") {
                $phase = "exit";
                $deadline = clock_gettime(CLOCK_MONOTONIC) + $exit_timeout;
            } elsif ($byte eq "T") {
                begin_termination("TERM");
            }
        }
    }
    last if reap_child();
}
exit($child_status // 1);
PERL
}

cmux_request_remote_demo_exit() {
  local supervisor_pid="$1"
  kill -USR2 "$supervisor_pid"
}

cmux_wait_for_remote_demo_ready() {
  local event_fd="$1"
  local app_pid
  local event
  local phase="transfer"
  CMUX_REMOTE_DEMO_APP_PID=""
  CMUX_REMOTE_DEMO_LAUNCHER_STATUS=""

  while IFS= read -r -u "$event_fd" event; do
    case "$event" in
      owner-started)
        [[ "$phase" == "transfer" ]] || return 22
        ;;
      daemon-starting)
        [[ "$phase" == "transfer" ]] || return 22
        phase="startup"
        ;;
      app-started\ *)
        [[ "$phase" == "startup" ]] || return 22
        app_pid="${event#app-started }"
        [[ -z "$CMUX_REMOTE_DEMO_APP_PID" ]] || return 22
        [[ "$app_pid" =~ ^[1-9][0-9]*$ ]] || return 22
        CMUX_REMOTE_DEMO_APP_PID="$app_pid"
        ;;
      ready)
        [[ "$phase" == "startup" ]] || return 22
        [[ "$CMUX_REMOTE_DEMO_APP_PID" =~ ^[1-9][0-9]*$ ]] || return 22
        return 0
        ;;
      transfer-timeout)
        [[ "$phase" == "transfer" ]] || return 22
        return 20
        ;;
      startup-timeout)
        [[ "$phase" == "startup" ]] || return 22
        return 21
        ;;
      launcher-exited\ *)
        CMUX_REMOTE_DEMO_LAUNCHER_STATUS="${event#launcher-exited }"
        [[ "$CMUX_REMOTE_DEMO_LAUNCHER_STATUS" =~ ^[0-9]+$ ]] || return 22
        return 10
        ;;
      failed\ [0-9]*) return 10 ;;
      *) return 22 ;;
    esac
  done
  return 10
}

cmux_wait_for_remote_demo_exit() {
  local event_fd="$1"
  local event
  local launcher_status
  CMUX_REMOTE_DEMO_LAUNCHER_STATUS=""

  while IFS= read -r -u "$event_fd" event; do
    case "$event" in
      failed\ [0-9]*) ;;
      launcher-exited\ *)
        launcher_status="${event#launcher-exited }"
        [[ "$launcher_status" =~ ^[0-9]+$ ]] || return 22
        CMUX_REMOTE_DEMO_LAUNCHER_STATUS="$launcher_status"
        return 0
        ;;
      exit-timeout) return 1 ;;
      *) return 22 ;;
    esac
  done
  return 1
}
