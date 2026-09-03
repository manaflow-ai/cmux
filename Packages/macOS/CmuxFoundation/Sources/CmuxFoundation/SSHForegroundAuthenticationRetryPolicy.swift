internal import Foundation

/// Classifies foreground SSH authentication failures without hiding interactive
/// prompts or retrying permanent authentication and configuration errors.
///
/// OpenSSH uses status 255 for both transport outages and permanent failures.
/// The persistent PTY wrappers therefore need stderr context before deciding
/// whether an initial authentication attempt belongs in their reconnect loop.
public struct SSHForegroundAuthenticationRetryPolicy: Sendable {
    /// Maximum consecutive initial transport failures before foreground auth surfaces the outage.
    public let maximumConsecutiveTransientFailures = 20

    /// Internal shell status for a status-255 failure with no recognized diagnostic.
    ///
    /// Before the first successful authentication, callers surface this as 255
    /// without retrying. An established persistent session may retry it because
    /// wake-related transport failures do not always emit a recognized diagnostic.
    public let unclassifiedFailureExitStatus = 252

    private let transientFailurePattern: String
    private let permanentFailurePattern: String

    /// Creates the policy used by cmux's foreground SSH authentication wrappers.
    public init() {
        transientFailurePattern = [
            "network is unreachable",
            "network is down",
            "no route to host",
            "host is down",
            "operation timed out",
            "connection timed out",
            "connection to .* timed out",
            "timeout, server .* not responding",
            "connection refused",
            "connection reset by peer",
            "connection reset by .* port [0-9]+",
            "connection closed by remote host",
            "connection closed by .* port [0-9]+",
            "connection to .* closed by remote host",
            "temporary failure in name resolution",
            "connection to .* port [0-9]+: broken pipe",
        ].joined(separator: "|")
        permanentFailurePattern = [
            "[^[:space:]]+@[^[:space:]]+: permission denied",
            "(zsh|bash|sh|dash|ksh|fish|csh|tcsh|env):.*permission denied",
            "host key verification failed",
            "remote host identification has changed",
            "authentication failed",
            "too many authentication failures",
            "bad owner or permissions",
            "bad configuration option",
            "no matching host key type found",
            "no matching cipher found",
            "no matching mac found",
            "no matching key exchange method found",
            "name or service not known",
            "nodename nor servname provided",
            "command not found",
            "(^|[^[:alnum:]_])(zsh|bash|sh|dash|ksh|fish|csh|tcsh|env):.*no such file or directory",
            "bad interpreter",
            "exec format error",
        ].joined(separator: "|")
    }

    /// Builds the shared result handler for persistent foreground authentication.
    ///
    /// A successful authentication arms persistent retry behavior. Before that
    /// first success, unclassified failures and the transient retry limit still
    /// fail closed. After success, transient and unclassified failures return to
    /// the surrounding reconnect loop, while classified permanent failures run
    /// `terminalFailureCommand` immediately.
    ///
    /// - Parameters:
    ///   - variablePrefix: Trusted POSIX-shell variable prefix for the wrapper's state.
    ///   - terminalFailureCommand: Shell command that terminates the surrounding retry loop.
    /// - Returns: One POSIX-shell line that handles the foreground authentication status.
    public func persistentAuthenticationResultShellLine(
        variablePrefix: String,
        terminalFailureCommand: String
    ) -> String {
        let status = "$\(variablePrefix)_status"
        let reauthenticationRequired = "\(variablePrefix)_reauth_required"
        let authenticationRetry = "\(variablePrefix)_auth_retry"
        let authenticationRetryLimit = "\(variablePrefix)_auth_retry_limit"
        let authenticationSucceeded = "\(variablePrefix)_auth_succeeded"
        return "if [ \"\(status)\" -eq 0 ]; then \(reauthenticationRequired)=0; \(authenticationRetry)=0; \(authenticationSucceeded)=1; else case \"\(status)\" in 254) \(authenticationRetry)=$((\(authenticationRetry) + 1)); if [ \"$\(authenticationSucceeded)\" -eq 0 ] && [ \"$\(authenticationRetry)\" -ge \"$\(authenticationRetryLimit)\" ]; then \(variablePrefix)_status=255; \(terminalFailureCommand); fi ;; \(unclassifiedFailureExitStatus)) \(variablePrefix)_status=255; if [ \"$\(authenticationSucceeded)\" -eq 0 ]; then \(terminalFailureCommand); fi ;; *) \(terminalFailureCommand) ;; esac; fi"
    }

    /// Builds the shell helper that terminates a foreground-authentication process tree.
    ///
    /// The helper takes one kernel process-table snapshot, indexes parent/child
    /// edges in one pass, and freezes the reachable tree with shell-builtin
    /// signals. Each accepted record carries its PID, parent, process group, and
    /// a host process-start identity. Darwin uses the microsecond kernel start
    /// token; Linux uses the monotonic `/proc` start counter.
    /// A second snapshot must confirm the identity and stopped state before the
    /// helper sends `SIGKILL`. Linux uses pidfds when available and an
    /// immediately revalidated `kill` fallback on kernels that reject pidfd
    /// syscalls. After `SIGTERM`, the helper waits for the
    /// per-attempt completion FIFO emitted by the authentication wrapper, then
    /// records descendants that still hold the attempt's marker descriptor.
    /// Failed snapshots never trigger an unverified signal. This keeps cleanup
    /// bounded when the runner cannot fork and avoids killing a reused PID.
    ///
    /// - Returns: A shell function named `cmux_ssh_terminate_auth_process_tree`.
    public func processTreeTerminationShellFunction() -> String {
        #"""
        cmux_ssh_terminate_auth_process_tree() (
          cmux_ssh_auth_tree_root_pid="$1"
          cmux_ssh_auth_tree_root_parent="$2"
          cmux_ssh_auth_wait_for_term_event_enabled="${3:-0}"
          case "$cmux_ssh_auth_tree_root_pid:$cmux_ssh_auth_tree_root_parent" in
            *[!0-9:]*|:*|*:) exit 0 ;;
          esac
          case "$cmux_ssh_auth_wait_for_term_event_enabled" in
            0|1) ;;
            *) cmux_ssh_auth_wait_for_term_event_enabled=0 ;;
          esac

          # Install a small failure trap before any filesystem operation. The
          # full cleanup trap needs the state files below, but setup failures
          # must still terminate the known root so its caller cannot wait
          # forever.
          cmux_ssh_auth_setup_failed=0
          cmux_ssh_auth_cleanup_complete=0
          cmux_ssh_auth_state_dir=
          cmux_ssh_auth_platform="$(uname -s 2>/dev/null || true)"
          cmux_ssh_auth_root_termination_identity=
          cmux_ssh_auth_perl_command="$(command -v perl 2>/dev/null || true)"
          cmux_ssh_auth_lsof_command="$(command -v lsof 2>/dev/null || true)"
          cmux_ssh_auth_capture_root_termination_identity() {
            case "$cmux_ssh_auth_platform" in
              Darwin)
                cmux_ssh_auth_root_termination_identity=$(
                  /usr/bin/ruby -rfiddle -rfiddle/import -e '
                    module CmuxLibproc
                      extend Fiddle::Importer
                      dlload "/usr/lib/libproc.dylib"
                      extern "int proc_pidinfo(int, int, unsigned long long, void*, int)"
                    end
                    pid = Integer(ARGV[0])
                    expected_parent = Integer(ARGV[1])
                    # Read the documented component flavors separately. Flavor
                    # 3 is PROC_PIDTBSDINFO (136 bytes), and flavor 17 is
                    # PROC_PIDUNIQIDENTIFIERINFO (56 bytes). This avoids making
                    # cleanup depend on the private combined flavor record
                    # size while retaining the kernel start time and pid version.
                    bsd_flavor = 3
                    uniqidentifier_flavor = 17
                    proc_bsdinfo_scalar_size = 4
                    proc_bsdinfo_status_offset = proc_bsdinfo_scalar_size
                    proc_bsdinfo_pid_offset = proc_bsdinfo_scalar_size * 3
                    proc_bsdinfo_ppid_offset = proc_bsdinfo_pid_offset + proc_bsdinfo_scalar_size
                    proc_bsdinfo_comm_offset = proc_bsdinfo_scalar_size * 12
                    proc_bsdinfo_name_offset = proc_bsdinfo_comm_offset + 16
                    proc_bsdinfo_nfiles_offset = proc_bsdinfo_name_offset + 32
                    proc_bsdinfo_pgid_offset = proc_bsdinfo_nfiles_offset + proc_bsdinfo_scalar_size
                    proc_bsdinfo_start_tvsec_offset = proc_bsdinfo_pgid_offset + proc_bsdinfo_scalar_size * 5
                    proc_bsdinfo_start_tvusec_offset = proc_bsdinfo_start_tvsec_offset + 8
                    proc_bsdinfo_size = proc_bsdinfo_start_tvusec_offset + 8
                    proc_uniqidentifierinfo_uuid_size = 16
                    proc_uniqidentifierinfo_unique_id_size = 8
                    proc_uniqidentifierinfo_pidversion_offset =
                      proc_uniqidentifierinfo_uuid_size + proc_uniqidentifierinfo_unique_id_size * 2
                    proc_uniqidentifierinfo_size =
                      proc_uniqidentifierinfo_pidversion_offset + 4 + 4 + 8 + 8
                    bsd_buffer = Fiddle::Pointer.malloc(proc_bsdinfo_size)
                    uniqidentifier_buffer = Fiddle::Pointer.malloc(proc_uniqidentifierinfo_size)
                    bsd_written = CmuxLibproc.proc_pidinfo(
                      pid, bsd_flavor, 0, bsd_buffer, proc_bsdinfo_size
                    )
                    uniqidentifier_written = CmuxLibproc.proc_pidinfo(
                      pid, uniqidentifier_flavor, 0, uniqidentifier_buffer,
                      proc_uniqidentifierinfo_size
                    )
                    exit 1 unless bsd_written == proc_bsdinfo_size &&
                      uniqidentifier_written == proc_uniqidentifierinfo_size
                    bsd_bytes = bsd_buffer.to_s(bsd_written)
                    uniqidentifier_bytes = uniqidentifier_buffer.to_s(uniqidentifier_written)
                    uint32 = ->(bytes, offset) { bytes.byteslice(offset, 4).unpack1("L<") }
                    uint64 = ->(bytes, offset) { bytes.byteslice(offset, 8).unpack1("Q<") }
                    observed_pid = uint32.call(bsd_bytes, proc_bsdinfo_pid_offset)
                    parent = uint32.call(bsd_bytes, proc_bsdinfo_ppid_offset)
                    group = uint32.call(bsd_bytes, proc_bsdinfo_pgid_offset)
                    status = uint32.call(bsd_bytes, proc_bsdinfo_status_offset)
                    seconds = uint64.call(bsd_bytes, proc_bsdinfo_start_tvsec_offset)
                    microseconds = uint64.call(bsd_bytes, proc_bsdinfo_start_tvusec_offset)
                    version = uint32.call(uniqidentifier_bytes, proc_uniqidentifierinfo_pidversion_offset)
                    exit 1 unless observed_pid == pid && parent == expected_parent &&
                      group > 0 && status != 5 && seconds > 0 &&
                      microseconds < 1_000_000 && version > 0
                    puts "D:#{pid}:#{parent}:#{group}:#{seconds}:#{microseconds}:#{version}"
                  ' "$cmux_ssh_auth_tree_root_pid" "$cmux_ssh_auth_tree_root_parent" 2>/dev/null
                ) || cmux_ssh_auth_root_termination_identity=
                ;;
              *)
                if [ -n "$cmux_ssh_auth_perl_command" ] &&
                   [ -r "/proc/$cmux_ssh_auth_tree_root_pid/stat" ]; then
                  cmux_ssh_auth_root_termination_identity=$(
                    "$cmux_ssh_auth_perl_command" -e '
                      use strict;
                      use warnings;
                      my ($pid, $expected_parent) = @ARGV;
                      open my $input, "<", "/proc/$pid/stat" or exit 1;
                      my $line = <$input>;
                      close $input;
                      chomp $line if defined $line;
                      exit 1 unless defined $line &&
                        $line =~ /\A([1-9][0-9]*) \(.*\) (.*)\z/;
                      my $observed_pid = $1;
                      my @fields = split /\s+/, $2;
                      exit 1 unless @fields >= 20;
                      my ($state, $parent, $group, $start) = @fields[0, 1, 2, 19];
                      $state = uc $state;
                      exit 1 unless $observed_pid eq $pid && $state ne "Z" &&
                        $parent eq $expected_parent && $group =~ /\A[1-9][0-9]*\z/ &&
                        $start =~ /\A[1-9][0-9]*\z/;
                      print "P:$pid:$parent:$group:$start\n";
                    ' "$cmux_ssh_auth_tree_root_pid" "$cmux_ssh_auth_tree_root_parent" 2>/dev/null
                  ) || cmux_ssh_auth_root_termination_identity=
                fi
                ;;
            esac
            case "$cmux_ssh_auth_root_termination_identity" in
              D:*|P:*) ;;
              *) cmux_ssh_auth_root_termination_identity= ;;
            esac
          }
          cmux_ssh_auth_force_root_termination() {
            case "$cmux_ssh_auth_root_termination_identity" in
              D:*)
                /usr/bin/ruby -rfiddle -rfiddle/import -e '
                  token = ARGV[0].to_s.split(":", -1)
                  exit 0 unless token.length == 7 && token[0] == "D"
                  begin
                    pid, parent, group, seconds, microseconds, version = token.drop(1).map(&:to_i)
                  rescue ArgumentError, TypeError
                    exit 0
                  end
                  exit 0 unless pid > 0 && parent >= 0 && group > 0 && seconds > 0 &&
                    microseconds >= 0 && microseconds < 1_000_000 && version > 0

                  module CmuxLibproc
                    extend Fiddle::Importer
                    dlload "/usr/lib/libproc.dylib"
                    extern "int proc_pidinfo(int, int, unsigned long long, void*, int)"
                    # libproc.h declares this private API as
                    # proc_signal_with_audittoken(audit_token_t *, int). The
                    # validated pid and pidversion live inside the token.
                    extern "int proc_signal_with_audittoken(void*, int)"
                  end
                  # Read the documented component flavors separately. Flavor
                  # 3 is PROC_PIDTBSDINFO (136 bytes), and flavor 17 is
                  # PROC_PIDUNIQIDENTIFIERINFO (56 bytes). Keep the validation
                  # symmetric with root capture and avoid the combined flavor
                  # private record-size assumptions.
                  bsd_flavor = 3
                  uniqidentifier_flavor = 17
                  proc_bsdinfo_scalar_size = 4
                  proc_bsdinfo_status_offset = proc_bsdinfo_scalar_size
                  proc_bsdinfo_pid_offset = proc_bsdinfo_scalar_size * 3
                  proc_bsdinfo_ppid_offset = proc_bsdinfo_pid_offset + proc_bsdinfo_scalar_size
                  proc_bsdinfo_comm_offset = proc_bsdinfo_scalar_size * 12
                  proc_bsdinfo_name_offset = proc_bsdinfo_comm_offset + 16
                  proc_bsdinfo_nfiles_offset = proc_bsdinfo_name_offset + 32
                  # libproc.h proc_bsdinfo layout places pbi_pgid after
                  # pbi_nfiles (offset 100), then pbi_nice (offset 116), with
                  # the two start-time uint64 values at offsets 120 and 128.
                  proc_bsdinfo_pgid_offset = proc_bsdinfo_nfiles_offset + proc_bsdinfo_scalar_size
                  proc_bsdinfo_start_tvsec_offset = proc_bsdinfo_pgid_offset + proc_bsdinfo_scalar_size * 5
                  proc_bsdinfo_start_tvusec_offset = proc_bsdinfo_start_tvsec_offset + 8
                  proc_bsdinfo_size = proc_bsdinfo_start_tvusec_offset + 8
                  proc_uniqidentifierinfo_uuid_size = 16
                  proc_uniqidentifierinfo_unique_id_size = 8
                  proc_uniqidentifierinfo_pidversion_offset =
                    proc_uniqidentifierinfo_uuid_size + proc_uniqidentifierinfo_unique_id_size * 2
                  proc_uniqidentifierinfo_size =
                    proc_uniqidentifierinfo_pidversion_offset + 4 + 4 + 8 + 8
                  bsd_buffer = Fiddle::Pointer.malloc(proc_bsdinfo_size)
                  uniqidentifier_buffer = Fiddle::Pointer.malloc(proc_uniqidentifierinfo_size)
                  bsd_written = CmuxLibproc.proc_pidinfo(
                    pid, bsd_flavor, 0, bsd_buffer, proc_bsdinfo_size
                  )
                  uniqidentifier_written = CmuxLibproc.proc_pidinfo(
                    pid, uniqidentifier_flavor, 0, uniqidentifier_buffer,
                    proc_uniqidentifierinfo_size
                  )
                  exit 0 unless bsd_written == proc_bsdinfo_size &&
                    uniqidentifier_written == proc_uniqidentifierinfo_size
                  bsd_bytes = bsd_buffer.to_s(bsd_written)
                  uniqidentifier_bytes = uniqidentifier_buffer.to_s(uniqidentifier_written)
                  uint32 = ->(bytes, offset) { bytes.byteslice(offset, 4).unpack1("L<") }
                  uint64 = ->(bytes, offset) { bytes.byteslice(offset, 8).unpack1("Q<") }
                  observed = [
                    uint32.call(bsd_bytes, proc_bsdinfo_pid_offset),
                    uint32.call(bsd_bytes, proc_bsdinfo_ppid_offset),
                    uint32.call(bsd_bytes, proc_bsdinfo_pgid_offset),
                    uint32.call(bsd_bytes, proc_bsdinfo_status_offset),
                    uint64.call(bsd_bytes, proc_bsdinfo_start_tvsec_offset),
                    uint64.call(bsd_bytes, proc_bsdinfo_start_tvusec_offset),
                    uint32.call(uniqidentifier_bytes, proc_uniqidentifierinfo_pidversion_offset)
                  ]
                  expected = [pid, parent, group, nil, seconds, microseconds, version]
                  exit 0 unless observed[0] == expected[0] && observed[1] == expected[1] &&
                    observed[2] == expected[2] && observed[3] != 5 && observed[4] == expected[4] &&
                    observed[5] == expected[5] && observed[6] == expected[6]
                  audit_token = Fiddle::Pointer.malloc(32)
                  audit_token[0, 32] = ([0xffffffff] * 8).pack("L<*")
                  audit_token[20, 4] = [pid].pack("L<")
                  audit_token[28, 4] = [version].pack("L<")
                  [19, 15, 9].each do |signal_number|
                    CmuxLibproc.proc_signal_with_audittoken(audit_token, signal_number)
                  end
                ' "$cmux_ssh_auth_root_termination_identity" >/dev/null 2>&1 || true
                ;;
              P:*)
                if [ -n "$cmux_ssh_auth_perl_command" ]; then
                  "$cmux_ssh_auth_perl_command" -e '
                  use strict;
                  use warnings;
                  use Errno qw(EACCES EINVAL EINTR EMFILE ENFILE ENOSYS EPERM);
                  use POSIX ();
                    my ($token) = @ARGV;
                    my ($kind, $pid, $parent, $group, $start) = split /:/, $token, -1;
                    exit 0 unless defined $kind && $kind eq "P" &&
                      defined $pid && $pid =~ /\A[1-9][0-9]*\z/ &&
                    defined $parent && $parent =~ /\A[0-9]+\z/ &&
                      defined $group && $group =~ /\A[1-9][0-9]*\z/ &&
                      defined $start && $start =~ /\A[1-9][0-9]*\z/;
                    my $pid_number = int($pid);
                    # Linux exposes pidfd_open and pidfd_send_signal at these
                    # stable syscall numbers. Older or sandboxed kernels can
                    # reject those calls, so the signal helper below performs
                    # one more identity read before using the Perl kill fallback.
                    my $pidfd_open_syscall = 434;
                    my $pidfd_send_signal_syscall = 424;
                    sub read_identity {
                      my ($candidate_pid) = @_;
                      open my $input, "<", "/proc/$candidate_pid/stat" or return;
                      my $line = <$input>;
                      close $input;
                      chomp $line if defined $line;
                      return unless defined $line &&
                        $line =~ /\A([1-9][0-9]*) \(.*\) (.*)\z/;
                      my $observed_pid = $1;
                      my @fields = split /\s+/, $2;
                      return unless @fields >= 20;
                      my ($state, $observed_parent, $observed_group, $observed_start) =
                        @fields[0, 1, 2, 19];
                      return unless $observed_pid eq $candidate_pid && uc($state) ne "Z" &&
                        $observed_parent =~ /\A[0-9]+\z/ &&
                        $observed_group =~ /\A[1-9][0-9]*\z/ &&
                        $observed_start =~ /\A[1-9][0-9]*\z/;
                      return [$observed_parent, $observed_group, $observed_start];
                    }
                    my $matches = sub {
                      my ($identity) = @_;
                      return defined $identity && $identity->[0] eq $parent &&
                        $identity->[1] eq $group && $identity->[2] eq $start;
                    };
                    my $identity = read_identity($pid);
                    exit 0 unless $matches->($identity);
                    my $pidfd_unavailable = 0;
                    my $send = sub {
                      my ($signal_number) = @_;
                      unless ($pidfd_unavailable) {
                        # Force the validated PID to an integer. Perl can pass
                        # a string scalar as a pointer to syscall on 64-bit
                        # hosts.
                        my $pidfd = syscall($pidfd_open_syscall, $pid_number, 0);
                        if (defined $pidfd && $pidfd >= 0) {
                          my $after_open = read_identity($pid);
                          unless ($matches->($after_open)) {
                            POSIX::close($pidfd);
                            return 0;
                          }
                          my $result = syscall(
                            $pidfd_send_signal_syscall, $pidfd, $signal_number, 0, 0
                          );
                          my $errno = 0 + $!;
                          POSIX::close($pidfd);
                          return 1 if defined $result && $result == 0;
                          return 0 unless $errno == EACCES || $errno == EINVAL ||
                            $errno == EINTR || $errno == EMFILE || $errno == ENFILE ||
                            $errno == ENOSYS || $errno == EPERM;
                        } else {
                          my $errno = 0 + $!;
                          return 0 unless $errno == EACCES || $errno == EINVAL ||
                            $errno == EINTR || $errno == EMFILE || $errno == ENFILE ||
                            $errno == ENOSYS || $errno == EPERM;
                        }
                        $pidfd_unavailable = 1;
                      }
                      # pidfd is unavailable on this host. Re-read the full
                      # procfs identity immediately before the compatibility
                      # signal so a reused PID is never accepted silently.
                      my $before_kill = read_identity($pid);
                      return 0 unless $matches->($before_kill);
                      return kill($signal_number, $pid_number) ? 1 : 0;
                    };
                    for my $signal_number (18, 15, 9) {
                      $send->($signal_number);
                    }
                  ' "$cmux_ssh_auth_root_termination_identity" >/dev/null 2>&1 || true
                fi
                ;;
            esac
          }
          cmux_ssh_auth_early_cleanup() {
            trap - EXIT HUP INT TERM
            if [ "$cmux_ssh_auth_setup_failed" = 1 ]; then
              cmux_ssh_auth_force_root_termination
              if [ -n "$cmux_ssh_auth_state_dir" ]; then
                /bin/rm -f -- "$cmux_ssh_auth_state_dir"/* 2>/dev/null || true
                /bin/rmdir "$cmux_ssh_auth_state_dir" 2>/dev/null || true
              fi
            fi
          }
          trap 'cmux_ssh_auth_early_cleanup' EXIT
          cmux_ssh_auth_setup_abort() {
            cmux_ssh_auth_setup_failed=1
            exit 0
          }
          cmux_ssh_auth_capture_root_termination_identity

          # Use Perl's monotonic clock for the shared cleanup budget. This is
          # independent of shell extensions such as bash's SECONDS, which are
          # absent from common POSIX shells. A failed clock probe stops the
          # cleanup pass; the bounded pass count is the final fallback.
          cmux_ssh_auth_cleanup_clock_command="$cmux_ssh_auth_perl_command"
          cmux_ssh_auth_cleanup_deadline_millis=
          if [ -n "$cmux_ssh_auth_cleanup_clock_command" ]; then
            cmux_ssh_auth_cleanup_deadline_millis=$(
              "$cmux_ssh_auth_cleanup_clock_command" \
                -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
                -e 'printf "%d\n", int(clock_gettime(CLOCK_MONOTONIC) * 1000)' \
                2>/dev/null
            ) || cmux_ssh_auth_cleanup_deadline_millis=
            case "$cmux_ssh_auth_cleanup_deadline_millis" in
              ''|*[!0-9]*) cmux_ssh_auth_cleanup_deadline_millis= ;;
              *) cmux_ssh_auth_cleanup_deadline_millis=$((cmux_ssh_auth_cleanup_deadline_millis + 2000)) ;;
            esac
          fi
          cmux_ssh_auth_cleanup_fallback_checks=0
          cmux_ssh_auth_get_remaining_millis() {
            if [ -n "$cmux_ssh_auth_cleanup_deadline_millis" ]; then
              cmux_ssh_auth_cleanup_now_millis=$(
                "$cmux_ssh_auth_cleanup_clock_command" \
                  -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
                  -e 'printf "%d\n", int(clock_gettime(CLOCK_MONOTONIC) * 1000)' \
                  2>/dev/null
              ) || return 1
              case "$cmux_ssh_auth_cleanup_now_millis" in
                ''|*[!0-9]*) return 1 ;;
              esac
              cmux_ssh_auth_remaining_millis=$((cmux_ssh_auth_cleanup_deadline_millis - cmux_ssh_auth_cleanup_now_millis))
              [ "$cmux_ssh_auth_remaining_millis" -gt 0 ]
              return $?
            fi
            cmux_ssh_auth_cleanup_fallback_checks=$((cmux_ssh_auth_cleanup_fallback_checks + 1))
            if [ "$cmux_ssh_auth_cleanup_fallback_checks" -le 4 ]; then
              # Without a monotonic clock, keep the same bounded fallback used
              # by cleanup_has_time and expose one conservative wait interval.
              cmux_ssh_auth_remaining_millis=1000
              return 0
            fi
            cmux_ssh_auth_remaining_millis=0
            return 1
          }
          cmux_ssh_auth_cleanup_has_time() {
            cmux_ssh_auth_get_remaining_millis
          }
          umask 077 || cmux_ssh_auth_setup_abort
          cmux_ssh_auth_state_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmux-ssh-auth-tree.XXXXXX") || cmux_ssh_auth_setup_abort
          [ -n "$cmux_ssh_auth_state_dir" ] || cmux_ssh_auth_setup_abort
          cmux_ssh_auth_snapshot="$cmux_ssh_auth_state_dir/snapshot"
          cmux_ssh_auth_members="$cmux_ssh_auth_state_dir/members"
          cmux_ssh_auth_pending="$cmux_ssh_auth_state_dir/pending"
          cmux_ssh_auth_owned="$cmux_ssh_auth_state_dir/owned"
          cmux_ssh_auth_live="$cmux_ssh_auth_state_dir/live"
          cmux_ssh_auth_term="$cmux_ssh_auth_state_dir/term"
          cmux_ssh_auth_term_candidates="$cmux_ssh_auth_state_dir/term-candidates"
          cmux_ssh_auth_stop_candidates="$cmux_ssh_auth_state_dir/stop-candidates"
          cmux_ssh_auth_kill_candidates="$cmux_ssh_auth_state_dir/kill-candidates"
          cmux_ssh_auth_root_identity_file="$cmux_ssh_auth_state_dir/root-identity"
          cmux_ssh_auth_root_identity_candidate="$cmux_ssh_auth_state_dir/root-identity-candidate"
          cmux_ssh_auth_dynamic_members="$cmux_ssh_auth_state_dir/dynamic-members"
          cmux_ssh_auth_marker_holders="$cmux_ssh_auth_state_dir/marker-holders"
          cmux_ssh_auth_marker_lsof_output="$cmux_ssh_auth_state_dir/marker-lsof"
          cmux_ssh_auth_root_identity=
          cmux_ssh_auth_event_token="${4:-${CMUX_SSH_AUTH_EVENT_TOKEN:-}}"
          case "$cmux_ssh_auth_event_token" in
            ''|*[!A-Za-z0-9_-]*) cmux_ssh_auth_event_token= ;;
          esac
          cmux_ssh_auth_term_event_dir=
          if [ -n "$cmux_ssh_auth_event_token" ]; then
            cmux_ssh_auth_term_event_dir="${TMPDIR:-/tmp}/cmux-ssh-auth-term.$cmux_ssh_auth_event_token"
          fi
          cmux_ssh_auth_term_event_fifo=
          cmux_ssh_auth_term_event_ack_fifo=
          cmux_ssh_auth_marker_path=
          cmux_ssh_auth_marker_identity_path=
          if [ -n "$cmux_ssh_auth_event_token" ]; then
            cmux_ssh_auth_marker_path="${TMPDIR:-/tmp}/cmux-ssh-auth-marker.$cmux_ssh_auth_event_token"
            cmux_ssh_auth_marker_identity_path="$cmux_ssh_auth_marker_path.identity"
            cmux_ssh_auth_term_event_fifo="$cmux_ssh_auth_term_event_dir/done"
            cmux_ssh_auth_term_event_ack_fifo="$cmux_ssh_auth_term_event_dir/ack"
          fi
          cmux_ssh_auth_term_event_owned=0
          cmux_ssh_auth_term_event_received=0
          cmux_ssh_auth_signal_backend=portable
          cmux_ssh_auth_snapshot_format=
          cmux_ssh_auth_cleanup_needs_root_abort=0
          cmux_ssh_auth_dynamic_discovery_failed=0
          if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
            cmux_ssh_auth_signal_backend=darwin
          fi
          : > "$cmux_ssh_auth_owned" || cmux_ssh_auth_setup_abort
          : > "$cmux_ssh_auth_pending" || cmux_ssh_auth_setup_abort
          : > "$cmux_ssh_auth_dynamic_members" || cmux_ssh_auth_setup_abort
          : > "$cmux_ssh_auth_marker_holders" || cmux_ssh_auth_setup_abort

          cmux_ssh_auth_take_snapshot() {
            if [ "$cmux_ssh_auth_signal_backend" = darwin ]; then
              # `ps lstart` is only second-resolution. Read proc_bsdinfo
              # directly so every snapshot carries the kernel birth timestamp
              # instead of a value that can collide after rapid PID reuse. One
              # Perl process walks the PID list, which keeps this path viable
              # under fork pressure and avoids one child process per candidate.
              if /usr/bin/perl -e '
              use strict;
              use warnings;
              my $max_pid_count = 65536;
              my $pid_buffer = "\0" x (4 * $max_pid_count);
              my $pid_bytes = syscall(336, 1, 1, 0, 0, $pid_buffer, length($pid_buffer));
              exit 1 unless defined($pid_bytes) && $pid_bytes >= 0 &&
                $pid_bytes < length($pid_buffer) && ($pid_bytes % 4) == 0;
              my %state = (1 => "I", 2 => "R", 3 => "S", 4 => "T", 5 => "Z");
              for (my $offset = 0; $offset < $pid_bytes; $offset += 4) {
                my $pid = unpack("L<", substr($pid_buffer, $offset, 4));
                next unless $pid > 0;
                my $info_buffer = "\0" x 184;
                my $info_size = syscall(336, 2, $pid, 3, 0, $info_buffer, length($info_buffer));
                my ($group_offset, $seconds_offset, $microseconds_offset);
                if ($info_size == 136) {
                  $group_offset = 100;
                  $seconds_offset = 120;
                  $microseconds_offset = 128;
                } elsif ($info_size == 184) {
                  $group_offset = 148;
                  $seconds_offset = 168;
                  $microseconds_offset = 176;
                } else {
                  next;
                }
                my $status = unpack("L<", substr($info_buffer, 4, 4));
                my $observed_pid = unpack("L<", substr($info_buffer, 12, 4));
                my $parent = unpack("L<", substr($info_buffer, 16, 4));
                my $group = unpack("L<", substr($info_buffer, $group_offset, 4));
                my $seconds = unpack("Q<", substr($info_buffer, $seconds_offset, 8));
                my $microseconds = unpack("Q<", substr($info_buffer, $microseconds_offset, 8));
                next unless $observed_pid == $pid && $group > 0 && $seconds > 0 &&
                  $microseconds < 1_000_000;
                next unless exists $state{$status};
                print "$pid $parent $group $state{$status} K $seconds $microseconds 0 0\n";
              }
              ' > "$cmux_ssh_auth_snapshot" 2>/dev/null &&
                 [ -s "$cmux_ssh_auth_snapshot" ]; then
                if [ -n "$cmux_ssh_auth_snapshot_format" ] &&
                   [ "$cmux_ssh_auth_snapshot_format" != darwin ]; then
                  cmux_ssh_auth_cleanup_needs_root_abort=1
                  return 1
                fi
                cmux_ssh_auth_snapshot_format=darwin
                return 0
              fi
              if [ -n "$cmux_ssh_auth_snapshot_format" ]; then
                # Do not mix kernel identities with second-resolution ps rows.
                # A later Darwin probe failure is handled by the root abort
                # path instead of silently dropping the ownership journal.
                cmux_ssh_auth_cleanup_needs_root_abort=1
                return 1
              fi
              # Linux exposes an exact monotonic process-start counter through
              # procfs. Do not substitute ps lstart here: its one-second value
              # is not an identity fence under PID reuse.
              cmux_ssh_auth_signal_backend=portable
            fi
            if [ ! -r /proc/1/stat ]; then
              cmux_ssh_auth_cleanup_needs_root_abort=1
              return 1
            fi
            cmux_ssh_auth_perl_command=$(command -v perl 2>/dev/null || true)
            if [ -z "$cmux_ssh_auth_perl_command" ]; then
              cmux_ssh_auth_cleanup_needs_root_abort=1
              return 1
            fi
            if [ -n "$cmux_ssh_auth_snapshot_format" ] &&
               [ "$cmux_ssh_auth_snapshot_format" != portable ]; then
              cmux_ssh_auth_cleanup_needs_root_abort=1
              return 1
            fi
            if ! "$cmux_ssh_auth_perl_command" -e '
              use strict;
              use warnings;
              opendir my $proc, "/proc" or exit 1;
              for my $entry (readdir $proc) {
                next unless $entry =~ /\A[1-9][0-9]*\z/;
                my $path = "/proc/$entry/stat";
                open my $input, "<", $path or next;
                my $line = <$input>;
                close $input;
                next unless defined $line;
                chomp $line;
                # The command name may contain spaces and closing parens. The
                # fields after the final close-parenthesis have the stable
                # procfs layout.
                next unless $line =~ /\A([1-9][0-9]*) \(.*\) (.*)\z/;
                my $pid = $1;
                my @fields = split /\s+/, $2;
                next unless @fields >= 20;
                my ($state, $parent, $group, $start) = @fields[0, 1, 2, 19];
                next unless $state =~ /\A[A-Za-z]\z/ &&
                  $parent =~ /\A[0-9]+\z/ && $group =~ /\A[1-9][0-9]*\z/ &&
                  $start =~ /\A[1-9][0-9]*\z/;
                $state = uc $state;
                print "$pid $parent $group $state P_${start} 0 0 0 0\n";
              }
            ' > "$cmux_ssh_auth_snapshot" 2>/dev/null; then
              cmux_ssh_auth_cleanup_needs_root_abort=1
              return 1
            fi
            if [ ! -s "$cmux_ssh_auth_snapshot" ]; then
              cmux_ssh_auth_cleanup_needs_root_abort=1
              return 1
            fi
            cmux_ssh_auth_snapshot_format=portable
            return 0
          }

          # The first process-table snapshot must describe the same kernel
          # identity captured before discovery started. PID and PPID alone are
          # not sufficient because a wrapper can exit and its PID can be
          # reused by another child of this shell before the snapshot runs.
          # Darwin's snapshot carries the kernel birth timestamp, while the
          # termination token also retains the pid version for the force path.
          cmux_ssh_auth_root_snapshot_matches_termination_identity() {
            # A failed identity probe cannot authorize even the initial root
            # record. Keep the helper fail-closed instead of falling back to
            # PID and PPID matching.
            [ -n "$cmux_ssh_auth_root_termination_identity" ] || return 1
            /usr/bin/awk \
              -v cmux_candidate="$1" \
              -v cmux_termination="$cmux_ssh_auth_root_termination_identity" '
                BEGIN {
                  cmux_candidate_count = split(cmux_candidate, cmux_candidate_fields, /[[:space:]]+/)
                  cmux_termination_count = split(cmux_termination, cmux_termination_fields, ":")
                  if (cmux_candidate_count != 4) exit 1
                  if (cmux_termination_fields[1] == "P" && cmux_termination_count == 5) {
                    cmux_started = "P_" cmux_termination_fields[5] "_0_0_0_0"
                    exit !(cmux_candidate_fields[1] == cmux_termination_fields[2] &&
                      cmux_candidate_fields[2] == cmux_termination_fields[3] &&
                      cmux_candidate_fields[3] == cmux_termination_fields[4] &&
                      cmux_candidate_fields[4] == cmux_started)
                  }
                  if (cmux_termination_fields[1] == "D" && cmux_termination_count == 7) {
                    cmux_started = "K_" cmux_termination_fields[5] "_" cmux_termination_fields[6] "_0_0"
                    exit !(cmux_candidate_fields[1] == cmux_termination_fields[2] &&
                      cmux_candidate_fields[2] == cmux_termination_fields[3] &&
                      cmux_candidate_fields[3] == cmux_termination_fields[4] &&
                      cmux_candidate_fields[4] == cmux_started)
                  }
                  exit 1
                }
              '
          }

          cmux_ssh_auth_extract_tree() {
            : > "$cmux_ssh_auth_members"
            : > "$cmux_ssh_auth_root_identity_candidate"
            /usr/bin/awk \
              -v cmux_root="$cmux_ssh_auth_tree_root_pid" \
              -v cmux_root_parent="$cmux_ssh_auth_tree_root_parent" \
              -v cmux_root_identity_candidate="$cmux_ssh_auth_root_identity_candidate" '
                NF >= 9 {
                  cmux_pid = $1
                  cmux_parent[cmux_pid] = $2
                  cmux_group[cmux_pid] = $3
                  cmux_state[cmux_pid] = $4
                  cmux_started[cmux_pid] = $5 "_" $6 "_" $7 "_" $8 "_" $9
                  cmux_row[cmux_pid] = cmux_pid " " $2 " " $3 " " $4 " " cmux_started[cmux_pid]
                  cmux_process[cmux_pid] = 1
                  cmux_children[$2] = cmux_children[$2] " " cmux_pid
                }
                END {
                  if (!(cmux_root in cmux_process) ||
                      cmux_parent[cmux_root] != cmux_root_parent ||
                      cmux_state[cmux_root] ~ /Z/) {
                    exit 1
                  }
                  print cmux_root " " cmux_parent[cmux_root] " " cmux_group[cmux_root] " " cmux_started[cmux_root] > cmux_root_identity_candidate
                  cmux_queue[1] = cmux_root
                  cmux_queue_head = 1
                  cmux_queue_tail = 1
                  cmux_depth[cmux_root] = 0
                  cmux_seen[cmux_root] = 1
                  while (cmux_queue_head <= cmux_queue_tail) {
                    cmux_parent_pid = cmux_queue[cmux_queue_head++]
                    print cmux_depth[cmux_parent_pid], cmux_row[cmux_parent_pid]
                    cmux_child_list = cmux_children[cmux_parent_pid]
                    if (cmux_child_list == "") continue
                    cmux_child_count = split(cmux_child_list, cmux_children_for_parent, /[[:space:]]+/)
                    for (cmux_index = 1; cmux_index <= cmux_child_count; cmux_index++) {
                      cmux_child_pid = cmux_children_for_parent[cmux_index]
                      if (cmux_child_pid == "" || cmux_child_pid in cmux_seen ||
                          !(cmux_child_pid in cmux_process) || cmux_state[cmux_child_pid] ~ /Z/) {
                        continue
                      }
                      cmux_seen[cmux_child_pid] = 1
                      cmux_depth[cmux_child_pid] = cmux_depth[cmux_parent_pid] + 1
                      cmux_queue[++cmux_queue_tail] = cmux_child_pid
                    }
                  }
                }
              ' "$cmux_ssh_auth_snapshot" > "$cmux_ssh_auth_members"
            cmux_ssh_auth_extract_status=$?
            if [ "$cmux_ssh_auth_extract_status" -ne 0 ]; then return "$cmux_ssh_auth_extract_status"; fi
            cmux_ssh_auth_root_identity_candidate_value=
            if ! IFS= read -r cmux_ssh_auth_root_identity_candidate_value < "$cmux_ssh_auth_root_identity_candidate"; then
              return 1
            fi
            if ! cmux_ssh_auth_root_snapshot_matches_termination_identity \
              "$cmux_ssh_auth_root_identity_candidate_value"; then
              # The captured identity is still safe to use for the root-only
              # abort path. Never journal or signal a tree from this snapshot.
              cmux_ssh_auth_cleanup_needs_root_abort=1
              return 1
            fi
            if [ -z "$cmux_ssh_auth_root_identity" ]; then
              cmux_ssh_auth_root_identity="$cmux_ssh_auth_root_identity_candidate_value"
              printf '%s\n' "$cmux_ssh_auth_root_identity" > "$cmux_ssh_auth_root_identity_file" || return 1
            elif [ "$cmux_ssh_auth_root_identity" != "$cmux_ssh_auth_root_identity_candidate_value" ]; then
              return 1
            fi
          }

          cmux_ssh_auth_append_pending() {
            while IFS= read -r cmux_ssh_auth_pending_line; do
              [ -n "$cmux_ssh_auth_pending_line" ] || continue
              printf '%s\n' "$cmux_ssh_auth_pending_line" >> "$cmux_ssh_auth_owned" || return 1
            done < "$cmux_ssh_auth_pending"
            : > "$cmux_ssh_auth_pending" || return 1
          }

          # A TERM handler can create a new session, exit, and leave its
          # replacement reparented before the next process-table snapshot. The
          # classifier therefore keeps a per-attempt marker FD open. The nested
          # shell unlinks the marker after opening descriptor 7. `lsof` then
          # matches the anonymous file by device and inode, including a detached
          # replacement that inherited the descriptor. Record its PID, parent,
          # PGID, and kernel start identity, then follow only current descendants.
          # No pathname opener or numeric process-group reuse can authorize an
          # unrelated process.
          cmux_ssh_auth_dynamic_discovery_abort() {
            cmux_ssh_auth_dynamic_discovery_failed=1
            cmux_ssh_auth_cleanup_needs_root_abort=1
            return 1
          }
          cmux_ssh_auth_record_dynamic_members() {
            if ! cmux_ssh_auth_take_snapshot; then
              cmux_ssh_auth_dynamic_discovery_abort
              return 1
            fi
            if ! : > "$cmux_ssh_auth_marker_holders"; then
              cmux_ssh_auth_dynamic_discovery_abort
              return 1
            fi
            if [ -n "$cmux_ssh_auth_event_token" ]; then
              if [ ! -s "$cmux_ssh_auth_marker_identity_path" ]; then
                cmux_ssh_auth_dynamic_discovery_abort
                return 1
              fi
              cmux_ssh_auth_marker_device_hex=
              cmux_ssh_auth_marker_device=
              cmux_ssh_auth_marker_inode=
              if ! IFS=' ' read -r cmux_ssh_auth_marker_device_hex cmux_ssh_auth_marker_device cmux_ssh_auth_marker_inode \
                < "$cmux_ssh_auth_marker_identity_path" ||
                 [ -z "$cmux_ssh_auth_marker_device_hex" ] ||
                 [ -z "$cmux_ssh_auth_marker_device" ] ||
                 [ -z "$cmux_ssh_auth_marker_inode" ]; then
                cmux_ssh_auth_dynamic_discovery_abort
                return 1
              fi
              # The marker is unlinked after the authentication shell opens
              # descriptor 7. Match the anonymous file by device and inode,
              # so a pathname opener cannot seed destructive ownership.
              if [ -z "$cmux_ssh_auth_lsof_command" ]; then
                cmux_ssh_auth_dynamic_discovery_abort
                return 1
              fi
              if ! : > "$cmux_ssh_auth_marker_lsof_output"; then
                cmux_ssh_auth_dynamic_discovery_abort
                return 1
              fi
              "$cmux_ssh_auth_lsof_command" -n -w -a -d 7 -F pfiD \
                > "$cmux_ssh_auth_marker_lsof_output" 2>/dev/null
              cmux_ssh_auth_marker_lsof_status=$?
              case "$cmux_ssh_auth_marker_lsof_status" in
                0) ;;
                *)
                  cmux_ssh_auth_dynamic_discovery_abort
                  return 1
                  ;;
              esac
              if /usr/bin/awk \
                -v cmux_marker_device="$cmux_ssh_auth_marker_device" \
                -v cmux_marker_device_hex="$cmux_ssh_auth_marker_device_hex" \
                -v cmux_marker_inode="$cmux_ssh_auth_marker_inode" '
                  function parse_error() { cmux_parse_error = 1 }
                  /^p/ {
                    if ($0 !~ /^p[0-9]+$/) parse_error()
                    else {
                      cmux_lsof_pid = substr($0, 2)
                      cmux_lsof_fd = ""
                      cmux_lsof_device = ""
                    }
                    next
                  }
                  /^f/ {
                    if ($0 !~ /^f.+$/) parse_error()
                    else {
                      cmux_lsof_fd = substr($0, 2)
                      cmux_lsof_device = ""
                    }
                    next
                  }
                  /^D/ {
                    if ($0 !~ /^D.+$/) parse_error()
                    else cmux_lsof_device = substr($0, 2)
                    next
                  }
                  /^i/ {
                    if ($0 !~ /^i[0-9]+$/ || cmux_lsof_pid !~ /^[0-9]+$/ ||
                        cmux_lsof_fd !~ /^7/) {
                      parse_error()
                    } else if (cmux_lsof_device != "" &&
                               (cmux_lsof_device == cmux_marker_device ||
                                cmux_lsof_device == cmux_marker_device_hex) &&
                               substr($0, 2) == cmux_marker_inode) {
                      print cmux_lsof_pid
                    }
                    next
                  }
                  { parse_error() }
                  END { exit cmux_parse_error ? 1 : 0 }
                ' "$cmux_ssh_auth_marker_lsof_output" > "$cmux_ssh_auth_marker_holders"; then
                :
              else
                cmux_ssh_auth_dynamic_discovery_abort
                return 1
              fi
              # A successful scan must prove at least one holder. An empty
              # result can mean that lsof could not inspect the process table,
              # so never let it silently authorize an empty lineage.
              if [ ! -s "$cmux_ssh_auth_marker_holders" ]; then
                cmux_ssh_auth_dynamic_discovery_abort
                return 1
              fi
            fi
            if ! /usr/bin/awk '
              FILENAME == ARGV[1] {
                # PPID is lineage metadata and can change when a TERM handler
                # outlives its parent. PID, PGID, and the kernel birth token
                # remain the stable identity fence.
                cmux_original_identity[$2 SUBSEP $4 SUBSEP $6] = 1
                next
              }
              FILENAME == ARGV[2] {
                if ($1 ~ /^[0-9]+$/) cmux_marker[$1] = 1
                next
              }
              NF >= 9 {
                cmux_pid = $1
                cmux_parent[cmux_pid] = $2
                cmux_group[cmux_pid] = $3
                cmux_state[cmux_pid] = $4
                cmux_started[cmux_pid] = $5 "_" $6 "_" $7 "_" $8 "_" $9
                cmux_process[cmux_pid] = 1
                cmux_children[$2] = cmux_children[$2] " " cmux_pid
              }
              END {
                # Marker holders are the roots of the post-TERM lineage. The
                # child walk remains identity-anchored to this one snapshot.
                for (cmux_pid in cmux_marker) {
                  if (cmux_pid in cmux_process && cmux_state[cmux_pid] !~ /Z/) {
                    cmux_lineage[cmux_pid] = 1
                    cmux_queue[++cmux_queue_tail] = cmux_pid
                  }
                }
                cmux_queue_head = 1
                while (cmux_queue_head <= cmux_queue_tail) {
                  cmux_parent_pid = cmux_queue[cmux_queue_head++]
                  cmux_child_list = cmux_children[cmux_parent_pid]
                  if (cmux_child_list == "") continue
                  cmux_child_count = split(cmux_child_list, cmux_children_for_parent, /[[:space:]]+/)
                  for (cmux_index = 1; cmux_index <= cmux_child_count; cmux_index++) {
                    cmux_child_pid = cmux_children_for_parent[cmux_index]
                    if (cmux_child_pid == "" || cmux_child_pid in cmux_lineage ||
                        cmux_state[cmux_child_pid] ~ /Z/) continue
                    cmux_lineage[cmux_child_pid] = 1
                    cmux_queue[++cmux_queue_tail] = cmux_child_pid
                  }
                }
                for (cmux_pid in cmux_lineage) {
                  cmux_started_id = cmux_started[cmux_pid]
                  if (cmux_state[cmux_pid] !~ /Z/ &&
                      !((cmux_pid SUBSEP cmux_group[cmux_pid] SUBSEP cmux_started_id) in cmux_original_identity)) {
                    print cmux_pid, cmux_parent[cmux_pid], cmux_group[cmux_pid], cmux_started_id
                  }
                }
              }
            ' "$cmux_ssh_auth_members" "$cmux_ssh_auth_marker_holders" \
              "$cmux_ssh_auth_snapshot" >> "$cmux_ssh_auth_dynamic_members"; then
              cmux_ssh_auth_dynamic_discovery_abort
              return 1
            fi
            return 0
          }

          # The generated authentication wrapper publishes the nonce only after
          # its TERM handler has waited for the command to finish. It then waits
          # for the helper ACK before exiting. This gives the helper a
          # happens-before edge for handler-created replacements while keeping
          # the wrapper alive during the post-TERM process-table snapshot. A
          # bounded read keeps plain fixtures and failed wrappers from blocking
          # cleanup.
          cmux_ssh_auth_wait_for_term_grace() {
            cmux_ssh_auth_get_remaining_millis || return 0
            [ -n "$cmux_ssh_auth_perl_command" ] || return 0
            "$cmux_ssh_auth_perl_command" -e '
              use strict;
              use warnings;
              my ($timeout_millis) = @ARGV;
              exit 0 unless defined $timeout_millis && $timeout_millis =~ /\A[1-9][0-9]*\z/;
              select undef, undef, undef, $timeout_millis / 1000;
            ' "$cmux_ssh_auth_remaining_millis" >/dev/null 2>&1 || true
          }

          cmux_ssh_auth_wait_for_term_event() {
            if [ "$cmux_ssh_auth_wait_for_term_event_enabled" != 1 ] ||
               [ -z "$cmux_ssh_auth_event_token" ]; then
              cmux_ssh_auth_wait_for_term_grace
              return 0
            fi
            if [ ! -p "$cmux_ssh_auth_term_event_fifo" ]; then
              cmux_ssh_auth_wait_for_term_grace
              return 0
            fi
            # Keep both descriptors below 10 because POSIX sh does not
            # require multi-digit redirection operands.
            if [ ! -p "$cmux_ssh_auth_term_event_ack_fifo" ] ||
               ! exec 8<> "$cmux_ssh_auth_term_event_ack_fifo"; then
              cmux_ssh_auth_wait_for_term_grace
              return 0
            fi
            if ! exec 9<> "$cmux_ssh_auth_term_event_fifo"; then
              exec 8>&-
              cmux_ssh_auth_wait_for_term_grace
              return 0
            fi
            cmux_ssh_auth_term_event_writer=
            # POSIX sh has no portable timed FIFO read. Use one Perl select
            # with the remaining monotonic budget, so process startup and the
            # wait itself cannot extend the shared cleanup deadline. The
            # helper already requires Perl for every process-table snapshot.
            if [ -n "$cmux_ssh_auth_perl_command" ] &&
               cmux_ssh_auth_get_remaining_millis; then
              cmux_ssh_auth_term_event_writer=$(
                "$cmux_ssh_auth_perl_command" -MIO::Select -e '
                  use strict;
                  use warnings;
                  use Fcntl qw(O_RDWR O_NONBLOCK);
                  my ($path, $timeout_millis) = @ARGV;
                  exit 0 unless defined $timeout_millis && $timeout_millis =~ /\A[1-9][0-9]*\z/;
                  sysopen(my $fifo, $path, O_RDWR | O_NONBLOCK) or exit 1;
                  my $select = IO::Select->new($fifo);
                  if ($select->can_read($timeout_millis / 1000)) {
                    my $line = <$fifo>;
                    print $line if defined $line;
                  }
                ' "$cmux_ssh_auth_term_event_fifo" \
                  "$cmux_ssh_auth_remaining_millis" 2>/dev/null || true
              )
            fi
            if [ "$cmux_ssh_auth_term_event_writer" = "$cmux_ssh_auth_event_token" ]; then
              cmux_ssh_auth_term_event_received=1
            else
              exec 9>&-
              cmux_ssh_auth_wait_for_term_grace
            fi
          }

          cmux_ssh_auth_ack_term_event() {
            if [ "$cmux_ssh_auth_term_event_received" = 1 ]; then
              printf '%s\n' "$cmux_ssh_auth_event_token" >&8 2>/dev/null || true
            fi
            exec 9>&-
          }

          # Validate and signal an identity batch. On Darwin, the shell/awk
          # snapshot is fenced again with the kernel audit token, which carries
          # the PID version. Linux uses a fresh procfs snapshot and pidfds so a
          # PID cannot be reused between validation and signal delivery. On an
          # older or sandboxed kernel that rejects pidfds, the Perl fallback
          # re-reads the full identity immediately before kill(2).
          # STOP candidates are journaled after the identity-checked request.
          # A confirming snapshot must prove the stopped state before TERM or
          # KILL. A stopped process cannot exit and reuse its PID, which closes
          # the destructive KILL window.
          cmux_ssh_auth_signal_portable_batch() {
            cmux_ssh_auth_portable_signal_name="$1"
            cmux_ssh_auth_portable_signal_input="$2"
            cmux_ssh_auth_portable_signal_output="${3:-/dev/null}"
            cmux_ssh_auth_portable_filter_stopped="${4:-1}"
            case "$cmux_ssh_auth_portable_signal_name" in
              STOP) cmux_ssh_auth_portable_require_stopped=0 ;;
              TERM|KILL) cmux_ssh_auth_portable_require_stopped=1 ;;
              CONT) cmux_ssh_auth_portable_require_stopped="$cmux_ssh_auth_portable_filter_stopped" ;;
              *) return 2 ;;
            esac
            cmux_ssh_auth_portable_candidates="$cmux_ssh_auth_state_dir/portable-candidates"
            : > "$cmux_ssh_auth_portable_candidates" || return 1
            if ! cmux_ssh_auth_filter_current_records \
              "$cmux_ssh_auth_portable_signal_input" \
              "$cmux_ssh_auth_portable_candidates" \
              "$cmux_ssh_auth_portable_require_stopped"; then
              return 1
            fi
            if [ -z "$cmux_ssh_auth_perl_command" ]; then
              /bin/rm -f "$cmux_ssh_auth_portable_candidates" 2>/dev/null || true
              return 1
            fi
            "$cmux_ssh_auth_perl_command" -e '
              use strict;
              use warnings;
              use Errno qw(EACCES EINVAL EINTR EMFILE ENFILE ENOSYS EPERM);
              use POSIX ();
              my ($signal_name, $input_path, $output_path, $require_stopped) = @ARGV;
              my %signals = (STOP => 19, TERM => 15, CONT => 18, KILL => 9);
              # Linux exposes pidfd_open and pidfd_send_signal at these stable
              # syscall numbers. Older or sandboxed kernels can reject those
              # calls, so the signal closure below performs one more identity
              # read before using the Perl compatibility kill path.
              my $pidfd_open_syscall = 434;
              my $pidfd_send_signal_syscall = 424;
              exit 2 unless exists $signals{$signal_name};

              sub read_identity {
                my ($candidate_pid) = @_;
                open my $input, "<", "/proc/$candidate_pid/stat" or return;
                my $line = <$input>;
                close $input;
                chomp $line if defined $line;
                return unless defined $line &&
                  $line =~ /\A([1-9][0-9]*) \(.*\) (.*)\z/;
                my $observed_pid = $1;
                my @fields = split /\s+/, $2;
                return unless @fields >= 20;
                my ($state, $parent, $group, $start) = @fields[0, 1, 2, 19];
                $state = uc $state;
                return unless $observed_pid eq $candidate_pid &&
                  $state ne "Z" && $parent =~ /\A[0-9]+\z/ &&
                  $group =~ /\A[1-9][0-9]*\z/ && $start =~ /\A[1-9][0-9]*\z/;
                return [$state, $parent, $group, $start];
              }
              sub matches {
                my ($identity, $parent, $group, $start) = @_;
                return defined $identity && $identity->[1] eq $parent &&
                  $identity->[2] eq $group && $identity->[3] eq $start;
              }

              open my $input, "<", $input_path or exit 1;
              open my $output, ">>", $output_path or exit 1;
              my $failed = 0;
              while (my $line = <$input>) {
                chomp $line;
                my @fields = split /\s+/, $line;
                next unless @fields == 6;
                my ($depth, $pid, $parent, $group, $original_state, $started) = @fields;
                next unless $depth =~ /\A[0-9]+\z/ && $pid =~ /\A[1-9][0-9]*\z/ &&
                  $parent =~ /\A[0-9]+\z/ && $group =~ /\A[1-9][0-9]*\z/ &&
                  $started =~ /\AP_[0-9]+_0_0_0_0\z/;
                my ($expected_start) = $started =~ /\AP_([0-9]+)_0_0_0_0\z/;
                next unless defined $expected_start;
                my $pid_number = int($pid);
                my $identity = read_identity($pid);
                next unless matches($identity, $parent, $group, $expected_start);
                if ($signal_name eq "STOP" && $identity->[0] =~ /T/) {
                  # A process that was already stopped in the candidate
                  # snapshot still belongs in the ownership journal. Do not
                  # send another STOP, and retain its original T state so a
                  # rollback will not resume it. A process that became stopped
                  # after the snapshot is not ours, so leave it unclaimed.
                  if ($original_state eq "T") {
                    print {$output} "$line\n" or $failed = 1;
                  }
                  next;
                }
                next if $signal_name eq "CONT" && $original_state =~ /T/;
                next if $signal_name =~ /\A(?:TERM|KILL)\z/ && $identity->[0] !~ /T/;
                next if $require_stopped eq "1" && $identity->[0] !~ /T/ &&
                  $signal_name ne "CONT";
                my $pidfd_unavailable = 0;
                my $send = sub {
                  my ($signal_number) = @_;
                  unless ($pidfd_unavailable) {
                    # Force the validated PID to an integer. Perl can pass a
                    # string scalar as a pointer to syscall on 64-bit hosts.
                    my $pidfd = syscall($pidfd_open_syscall, $pid_number, 0);
                    if (defined $pidfd && $pidfd >= 0) {
                      my $after_open = read_identity($pid);
                      unless (matches($after_open, $parent, $group, $expected_start)) {
                        POSIX::close($pidfd);
                        return 0;
                      }
                      my $result = syscall(
                        $pidfd_send_signal_syscall, $pidfd, $signal_number, 0, 0
                      );
                      my $errno = 0 + $!;
                      POSIX::close($pidfd);
                      return 1 if defined $result && $result == 0;
                      return 0 unless $errno == EACCES || $errno == EINVAL ||
                        $errno == EINTR || $errno == EMFILE || $errno == ENFILE ||
                        $errno == ENOSYS || $errno == EPERM;
                    } else {
                      my $errno = 0 + $!;
                      return 0 unless $errno == EACCES || $errno == EINVAL ||
                        $errno == EINTR || $errno == EMFILE || $errno == ENFILE ||
                        $errno == ENOSYS || $errno == EPERM;
                    }
                    $pidfd_unavailable = 1;
                  }
                  # pidfd is unavailable on this host. Re-read the full
                  # procfs identity immediately before the compatibility
                  # signal so a reused PID is never accepted silently.
                  my $before_kill = read_identity($pid);
                  return 0 unless matches($before_kill, $parent, $group, $expected_start);
                  return kill($signal_number, $pid_number) ? 1 : 0;
                };
                if ($signal_name eq "STOP") {
                  if ($send->($signals{STOP})) {
                    print {$output} "$line\n" or $failed = 1;
                  } else {
                    $failed = 1;
                  }
                } elsif ($signal_name eq "TERM") {
                  my $term_ok = $send->($signals{TERM});
                  my $cont_ok = $send->($signals{CONT});
                  unless ($term_ok && $cont_ok) {
                    # An exited target is already cleaned up. A surviving
                    # target means this batch did not complete and must stay
                    # on the bounded retry or root-abort path.
                    $failed = 1 if defined read_identity($pid);
                  }
                } elsif ($signal_name eq "CONT") {
                  unless ($send->($signals{CONT})) {
                    my $current = read_identity($pid);
                    $failed = 1 if matches($current, $parent, $group, $expected_start) &&
                      $current->[0] =~ /T/;
                  }
                } elsif ($signal_name eq "KILL") {
                  unless ($send->($signals{KILL})) {
                    my $current = read_identity($pid);
                    $failed = 1 if matches($current, $parent, $group, $expected_start) &&
                      $current->[0] =~ /T/;
                  }
                }
              }
              close $input;
              close $output;
              exit $failed ? 1 : 0;
            ' "$cmux_ssh_auth_signal_name" "$cmux_ssh_auth_portable_candidates" \
              "$cmux_ssh_auth_portable_signal_output" "$cmux_ssh_auth_portable_require_stopped"
            cmux_ssh_auth_portable_status=$?
            /bin/rm -f "$cmux_ssh_auth_portable_candidates" 2>/dev/null || true
            [ "$cmux_ssh_auth_portable_status" -eq 0 ]
          }

          cmux_ssh_auth_signal_verified_batch() {
            cmux_ssh_auth_signal_name="$1"
            cmux_ssh_auth_signal_input="$2"
            cmux_ssh_auth_signal_output="${3:-/dev/null}"
            cmux_ssh_auth_signal_filter_stopped="${4:-1}"
            if [ "$cmux_ssh_auth_signal_backend" != darwin ]; then
              cmux_ssh_auth_signal_portable_batch \
                "$cmux_ssh_auth_signal_name" \
                "$cmux_ssh_auth_signal_input" \
                "$cmux_ssh_auth_signal_output" \
                "$cmux_ssh_auth_signal_filter_stopped"
              cmux_ssh_auth_signal_status=$?
              if [ "$cmux_ssh_auth_signal_status" -ne 0 ]; then
                cmux_ssh_auth_cleanup_needs_root_abort=1
              fi
              return "$cmux_ssh_auth_signal_status"
            fi
            /usr/bin/ruby -rfiddle -rfiddle/import -e '
              signal_name, input_path, output_path = ARGV
              signals = { "STOP" => 17, "TERM" => 15, "CONT" => 19, "KILL" => 9 }
              exit 2 unless signals.key?(signal_name) && input_path && output_path

              module CmuxLibproc
                    extend Fiddle::Importer
                    dlload "/usr/lib/libproc.dylib"
                    extern "int proc_pidinfo(int, int, unsigned long long, void*, int)"
                    # libproc.h declares this private API as
                    # proc_signal_with_audittoken(audit_token_t *, int). The
                    # validated pid and pidversion live inside the token.
                    extern "int proc_signal_with_audittoken(void*, int)"
              end

              bsd_flavor = 3
              uniqidentifier_flavor = 17
              proc_bsdinfo_scalar_size = 4
              proc_bsdinfo_status_offset = proc_bsdinfo_scalar_size
              proc_bsdinfo_pid_offset = proc_bsdinfo_scalar_size * 3
              proc_bsdinfo_ppid_offset = proc_bsdinfo_pid_offset + proc_bsdinfo_scalar_size
                    proc_bsdinfo_comm_offset = proc_bsdinfo_scalar_size * 12
                    proc_bsdinfo_name_offset = proc_bsdinfo_comm_offset + 16
                    proc_bsdinfo_nfiles_offset = proc_bsdinfo_name_offset + 32
                    # libproc.h proc_bsdinfo layout places pbi_pgid after
                    # pbi_nfiles (offset 100), then pbi_nice (offset 116), with
                    # the two start-time uint64 values at offsets 120 and 128.
                    proc_bsdinfo_pgid_offset = proc_bsdinfo_nfiles_offset + proc_bsdinfo_scalar_size
              proc_bsdinfo_start_tvsec_offset = proc_bsdinfo_pgid_offset + proc_bsdinfo_scalar_size * 5
              proc_bsdinfo_start_tvusec_offset = proc_bsdinfo_start_tvsec_offset + 8
              proc_bsdinfo_size = proc_bsdinfo_start_tvusec_offset + 8
              proc_uniqidentifierinfo_uuid_size = 16
              proc_uniqidentifierinfo_unique_id_size = 8
              uint32 = ->(bytes, offset) { bytes.byteslice(offset, 4).unpack1("L<") }
              uint64 = ->(bytes, offset) { bytes.byteslice(offset, 8).unpack1("Q<") }
              # `proc_uniqidentifierinfo` stores its UUID first, then the
              # process and parent unique IDs, followed by `p_idversion`.
              proc_uniqidentifierinfo_pidversion_offset =
                proc_uniqidentifierinfo_uuid_size + proc_uniqidentifierinfo_unique_id_size * 2
              proc_uniqidentifierinfo_size =
                proc_uniqidentifierinfo_pidversion_offset + 4 + 4 + 8 + 8
              process_identity = lambda do |pid|
                bsd_buffer = Fiddle::Pointer.malloc(proc_bsdinfo_size)
                uniqidentifier_buffer = Fiddle::Pointer.malloc(proc_uniqidentifierinfo_size)
                bsd_written = CmuxLibproc.proc_pidinfo(
                  Integer(pid), bsd_flavor, 0, bsd_buffer, proc_bsdinfo_size
                )
                uniqidentifier_written = CmuxLibproc.proc_pidinfo(
                  Integer(pid), uniqidentifier_flavor, 0, uniqidentifier_buffer,
                  proc_uniqidentifierinfo_size
                )
                next nil unless bsd_written == proc_bsdinfo_size &&
                  uniqidentifier_written == proc_uniqidentifierinfo_size
                bsd_bytes = bsd_buffer.to_s(bsd_written)
                uniqidentifier_bytes = uniqidentifier_buffer.to_s(uniqidentifier_written)
                [
                  uint32.call(bsd_bytes, proc_bsdinfo_pid_offset), # pbi_pid
                  uint32.call(bsd_bytes, proc_bsdinfo_ppid_offset), # pbi_ppid
                  uint32.call(bsd_bytes, proc_bsdinfo_pgid_offset), # pbi_pgid
                  uint32.call(bsd_bytes, proc_bsdinfo_status_offset), # pbi_status
                  uint64.call(bsd_bytes, proc_bsdinfo_start_tvsec_offset), # pbi_start_tvsec
                  uint64.call(bsd_bytes, proc_bsdinfo_start_tvusec_offset), # pbi_start_tvusec
                  uint32.call(uniqidentifier_bytes, proc_uniqidentifierinfo_pidversion_offset), # p_idversion
                ]
              rescue ArgumentError, Fiddle::DLError, NoMethodError, RangeError, TypeError
                nil
              end
              same_identity = lambda do |identity, pid, group, seconds, microseconds|
                identity && identity.length == 7 && identity[0] == pid &&
                  identity[2] == group && identity[4] == seconds && identity[5] == microseconds
              end
              signal_exact = lambda do |identity, signal_number|
                token = Fiddle::Pointer.malloc(32)
                token[0, 32] = ([0xffffffff] * 8).pack("L<*")
                token[20, 4] = [identity[0]].pack("L<")
                token[28, 4] = [identity[6]].pack("L<")
                CmuxLibproc.proc_signal_with_audittoken(token, signal_number) == 0
              end

              begin
                input = File.open(input_path, "r")
                output = File.open(output_path, "w")
                signal_failed = false
                input.each_line do |line|
                fields = line.split
                next unless fields.length == 6
                depth, pid_text, parent_text, group_text, original_state, started = fields
                next unless depth.match?(/\A[0-9]+\z/) && pid_text.match?(/\A[1-9][0-9]*\z/) &&
                  parent_text.match?(/\A[0-9]+\z/) && group_text.match?(/\A[1-9][0-9]*\z/)
                match = started.match(/\AK_([0-9]+)_([0-9]+)_0_0\z/)
                next unless match
                expected_seconds = Integer(match[1])
                expected_microseconds = Integer(match[2])
                next if expected_microseconds >= 1_000_000
                pid = Integer(pid_text)
                group = Integer(group_text)
                before = process_identity.call(pid)
                next unless same_identity.call(before, pid, group, expected_seconds, expected_microseconds)
                next if before[3] == 5

                if signal_name == "STOP"
                  if before[3] == 4
                    # Preserve a process that was already stopped in the
                    # candidate snapshot without sending another STOP. The
                    # original T state prevents rollback from resuming it.
                    output.puts(line.chomp) if original_state == "T"
                    next
                  end
                  next unless signal_exact.call(before, signals[signal_name])
                  # SIGSTOP delivery can be asynchronous to proc_pidinfo. The
                  # audit-token call already verified this exact identity, so
                  # journal every successful STOP immediately. A later pass
                  # confirms the stopped state before TERM or KILL; rollback
                  # sends CONT even if that state check still sees the process
                  # running, which prevents a delayed STOP from stranding it.
                  output.puts(line.chomp)
                  next
                end

                # Rollback never resumes a process that was already stopped
                # before this helper acquired it.
                next if signal_name == "CONT" && original_state == "T"
                if signal_name == "CONT"
                  unless signal_exact.call(before, signals[signal_name])
                    current = process_identity.call(pid)
                    signal_failed = true if same_identity.call(
                      current, pid, group, expected_seconds, expected_microseconds
                    ) && current[3] == 4
                  end
                  next
                end
                next unless before[3] == 4
                if signal_name == "TERM"
                  unless signal_exact.call(before, signals[signal_name])
                    current = process_identity.call(pid)
                    signal_exact.call(current, signals["CONT"]) if same_identity.call(
                      current, pid, group, expected_seconds, expected_microseconds
                    ) && current[3] == 4
                    next
                  end
                  after = process_identity.call(pid)
                  signal_exact.call(after, signals["CONT"]) if same_identity.call(
                    after, pid, group, expected_seconds, expected_microseconds
                  ) && after[3] == 4
                else
                  unless signal_exact.call(before, signals[signal_name])
                    # A process may exit between validation and KILL. Treat
                    # that race as success, but report a live matching stop so
                    # the caller resumes it instead of declaring cleanup done.
                    current = process_identity.call(pid)
                    signal_failed = true if same_identity.call(
                      current, pid, group, expected_seconds, expected_microseconds
                    ) && current[3] == 4
                  end
                end
                end
                exit 1 if signal_failed
              ensure
                input&.close
                output&.close
              end
          ' "$cmux_ssh_auth_signal_name" "$cmux_ssh_auth_signal_input" \
              "$cmux_ssh_auth_signal_output" >/dev/null 2>&1
            cmux_ssh_auth_signal_status=$?
            if [ "$cmux_ssh_auth_signal_status" -ne 0 ]; then
              cmux_ssh_auth_cleanup_needs_root_abort=1
            fi
            return "$cmux_ssh_auth_signal_status"
          }

          cmux_ssh_auth_resume_kernel_journal() {
            # A STOP may still be in flight when the confirming snapshot runs.
            # Include matching running rows so CONT cancels that delayed stop.
            cmux_ssh_auth_signal_verified_batch CONT "$1" /dev/null 0 || true
          }

          cmux_ssh_auth_resume_unconfirmed_stops() {
            cmux_ssh_auth_resume_path="$1"
            [ -s "$cmux_ssh_auth_resume_path" ] || return 0
            cmux_ssh_auth_resume_kernel_journal "$cmux_ssh_auth_resume_path"
          }

          # Re-read the process table once immediately before each signal
          # batch. Every row carries PID, PPID, PGID, and a kernel-start token.
          # The stable key uses PID, PGID, and that token because PPID changes
          # during expected reparenting. Root validation and child edges still
          # require the recorded PPID, so PID reuse cannot authorize a signal.
          cmux_ssh_auth_filter_current_records() {
            cmux_ssh_auth_filter_input="$1"
            cmux_ssh_auth_filter_output="$2"
            cmux_ssh_auth_filter_stopped="$3"
            : > "$cmux_ssh_auth_filter_output" || return 1
            cmux_ssh_auth_take_snapshot || return 1
            /usr/bin/awk -v cmux_require_stopped="$cmux_ssh_auth_filter_stopped" '
              FILENAME == ARGV[1] {
                cmux_key = $2 SUBSEP $4 SUBSEP $6
                if (!(cmux_key in cmux_expected)) {
                  cmux_expected[cmux_key] = $0
                  cmux_order[++cmux_count] = cmux_key
                }
                next
              }
              NF >= 9 {
                cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                cmux_key = $1 SUBSEP $3 SUBSEP cmux_started
                if ((cmux_key in cmux_expected) && $4 !~ /Z/ &&
                    (cmux_require_stopped != 1 || $4 ~ /T/)) {
                  cmux_valid[cmux_key] = 1
                }
              }
              END {
                for (cmux_index = 1; cmux_index <= cmux_count; cmux_index++) {
                  cmux_key = cmux_order[cmux_index]
                  if (cmux_key in cmux_valid) print cmux_expected[cmux_key]
                }
              }
            ' "$cmux_ssh_auth_filter_input" "$cmux_ssh_auth_snapshot" \
              > "$cmux_ssh_auth_filter_output"
          }

          cmux_ssh_auth_resume_file() {
            cmux_ssh_auth_resume_path="$1"
            [ -s "$cmux_ssh_auth_resume_path" ] || return 0
            cmux_ssh_auth_resume_kernel_journal "$cmux_ssh_auth_resume_path"
          }

          cmux_ssh_auth_cleanup() {
            trap - EXIT HUP INT TERM
            if [ "$cmux_ssh_auth_cleanup_complete" != 1 ]; then
              cmux_ssh_auth_resume_file "$cmux_ssh_auth_pending"
              cmux_ssh_auth_resume_file "$cmux_ssh_auth_owned"
              if [ "$cmux_ssh_auth_cleanup_needs_root_abort" = 1 ]; then
                cmux_ssh_auth_force_root_termination
              fi
            fi
            # Once the wrapper opens the per-attempt event FIFOs, marker
            # identity cleanup is handed to this helper. The wrapper may time
            # out while waiting for the ACK, but the identity record must stay
            # available until every post-TERM discovery pass has finished.
            if [ "$cmux_ssh_auth_term_event_owned" = 1 ] && [ -n "$cmux_ssh_auth_marker_path" ]; then
              /bin/rm -f -- "$cmux_ssh_auth_marker_path" "$cmux_ssh_auth_marker_identity_path" 2>/dev/null || true
            fi
            if [ "$cmux_ssh_auth_term_event_owned" = 1 ]; then
              /bin/rm -f "$cmux_ssh_auth_term_event_fifo" "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null || true
            fi
            # Unlink the FIFOs before closing the helper's descriptors. The
            # open ACK descriptor keeps a wrapper-side read from blocking when
            # the event wait times out; unlinking first also wakes a reader
            # that races with cleanup.
            exec 9>&- 2>/dev/null || true
            exec 8>&- 2>/dev/null || true
            /bin/rm -f "$cmux_ssh_auth_snapshot" "$cmux_ssh_auth_members" \
              "$cmux_ssh_auth_pending" "$cmux_ssh_auth_owned" \
              "$cmux_ssh_auth_live" "$cmux_ssh_auth_term" \
              "$cmux_ssh_auth_term_candidates" "$cmux_ssh_auth_stop_candidates" \
              "$cmux_ssh_auth_kill_candidates" \
              "$cmux_ssh_auth_root_identity_file" "$cmux_ssh_auth_root_identity_candidate" \
              "$cmux_ssh_auth_dynamic_members" "$cmux_ssh_auth_marker_holders" \
              "$cmux_ssh_auth_marker_lsof_output" \
              2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_state_dir" 2>/dev/null || true
          }
          trap 'cmux_ssh_auth_cleanup' EXIT
          trap 'exit 129' HUP
          trap 'exit 130' INT
          trap 'exit 143' TERM

          # Validate the known root parent and build the first breadth-first
          # member list. The root is stopped first in that order.
          if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_tree; then exit 0; fi
          # The authentication wrapper derives this same path from the fresh
          # per-attempt nonce. A pre-existing path is never removed or reused,
          # so a stale process cannot receive an event from this attempt.
          if [ "$cmux_ssh_auth_wait_for_term_event_enabled" = 1 ] &&
             [ -n "$cmux_ssh_auth_event_token" ] &&
             /bin/mkdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null; then
            if /usr/bin/mkfifo "$cmux_ssh_auth_term_event_fifo" 2>/dev/null && \
               /usr/bin/mkfifo "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null; then
              cmux_ssh_auth_term_event_owned=1
            else
              exec 9>&- 2>/dev/null || true
              exec 8>&- 2>/dev/null || true
              # The directory was created by this invocation. Remove only its
              # own partial setup. A mkdir collision never reaches this path,
              # so a stale attempt's FIFOs remain untouched.
              /bin/rm -f "$cmux_ssh_auth_term_event_fifo" "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null || true
              cmux_ssh_auth_term_event_fifo=
              cmux_ssh_auth_term_event_ack_fifo=
            fi
          fi
          cmux_ssh_auth_freeze_attempt=0
          cmux_ssh_auth_tree_frozen=0
          while [ "$cmux_ssh_auth_freeze_attempt" -lt 4 ] && cmux_ssh_auth_cleanup_has_time; do
            # Refresh immediately before each STOP batch. The confirmation
            # below is the identity fence: a PID that changed between this
            # snapshot and STOP is resumed and never enters TERM/KILL ownership.
            if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_tree; then
              cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
              break
            fi
            if ! cmux_ssh_auth_filter_current_records \
              "$cmux_ssh_auth_members" "$cmux_ssh_auth_stop_candidates" 0; then
              cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
              break
            fi
            : > "$cmux_ssh_auth_pending"
            # Only STOP operations that pass the in-process identity fence
            # enter the pending ownership journal.
            cmux_ssh_auth_signal_verified_batch STOP \
              "$cmux_ssh_auth_stop_candidates" "$cmux_ssh_auth_pending" || exit 0
            cmux_ssh_auth_append_pending || exit 0

            if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_tree; then
              cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
              break
            fi
            if /usr/bin/awk '
                FILENAME == ARGV[1] { cmux_owned[$2 SUBSEP $4 SUBSEP $6] = 1; next }
                $5 !~ /Z/ && ($2 SUBSEP $4 SUBSEP $6) in cmux_owned && $5 ~ /T/ { next }
                $5 !~ /Z/ { exit 1 }
              ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_members"; then
              cmux_ssh_auth_tree_frozen=1
              break
            fi
            cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
            cmux_ssh_auth_freeze_attempt=$((cmux_ssh_auth_freeze_attempt + 1))
          done
          [ "$cmux_ssh_auth_tree_frozen" = 1 ] || exit 0

          # Signal leaves first. This preserves TERM handlers that restore the
          # terminal or launch a short-lived replacement process.
          if ! cmux_ssh_auth_filter_current_records \
            "$cmux_ssh_auth_owned" "$cmux_ssh_auth_term_candidates" 1; then
            cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
            exit 0
          fi
          /usr/bin/awk '
            {
              cmux_key = $2 SUBSEP $4 SUBSEP $6
              if (cmux_key in cmux_seen) next
              cmux_seen[cmux_key] = 1
              cmux_record[cmux_key] = $0
              cmux_bucket[$1] = cmux_bucket[$1] " " cmux_key
              if ($1 > cmux_max_depth) cmux_max_depth = $1
            }
            END {
              for (cmux_depth = cmux_max_depth; cmux_depth >= 0; cmux_depth--) {
                cmux_count = split(cmux_bucket[cmux_depth], cmux_keys, /[[:space:]]+/)
                for (cmux_index = 1; cmux_index <= cmux_count; cmux_index++) {
                  if (cmux_keys[cmux_index] != "") print cmux_record[cmux_keys[cmux_index]]
                }
              }
            }
          ' "$cmux_ssh_auth_term_candidates" > "$cmux_ssh_auth_term" || exit 0
          cmux_ssh_auth_signal_verified_batch TERM "$cmux_ssh_auth_term" /dev/null || true
          # The wrapper sends its event immediately after forwarding TERM and
          # waits for our ACK. Snapshot before ACK so a replacement is still
          # attached to the live wrapper even when its direct parent exits.
          cmux_ssh_auth_wait_for_term_event
          cmux_ssh_auth_record_dynamic_members || true
          # Refresh once more before releasing the wrapper. The marker-FD
          # identity journal remains valid after reparenting.
          cmux_ssh_auth_record_dynamic_members || true
          cmux_ssh_auth_ack_term_event
          # Missing marker proof cannot authorize a replacement, but the
          # original owned journal is already identity-fenced. Continue through
          # the bounded force phase so verified descendants do not survive a
          # discovery-tool failure. The EXIT trap will still force the known
          # root and will leave any unclaimed replacement untouched.
          if [ "$cmux_ssh_auth_dynamic_discovery_failed" = 1 ]; then
            cmux_ssh_auth_cleanup_needs_root_abort=1
          fi

          # Rebuild ownership from exact identities and descendants. Marker-FD
          # identities catch a replacement that outlives its parent without
          # broadening ownership to unrelated process-group members.
          cmux_ssh_auth_extract_owned() {
            : > "$cmux_ssh_auth_live"
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                cmux_owned_identity[$2 SUBSEP $4 SUBSEP $6] = 1
                next
              }
              FILENAME == ARGV[2] {
                if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ &&
                    $3 ~ /^[0-9]+$/ && $4 != "") {
                  cmux_dynamic_identity[$1 SUBSEP $3 SUBSEP $4] = 1
                }
                next
              }
              NF >= 9 {
                cmux_pid = $1
                cmux_parent[cmux_pid] = $2
                cmux_group[cmux_pid] = $3
                cmux_state[cmux_pid] = $4
                cmux_started[cmux_pid] = $5 "_" $6 "_" $7 "_" $8 "_" $9
                cmux_row[cmux_pid] = cmux_pid " " $2 " " $3 " " $4 " " cmux_started[cmux_pid]
                cmux_process[cmux_pid] = 1
                cmux_children[$2] = cmux_children[$2] " " cmux_pid
                cmux_identity_key = cmux_pid SUBSEP $3 SUBSEP cmux_started[cmux_pid]
                if (cmux_identity_key in cmux_owned_identity ||
                    cmux_identity_key in cmux_dynamic_identity) {
                  cmux_seen[cmux_pid] = 1
                  cmux_queue[++cmux_queue_tail] = cmux_pid
                  cmux_depth[cmux_pid] = 0
                }
              }
              END {
                # Ownership is identity-based only. Do not expand a process
                # group by numeric PGID: the ID can be reused, and an
                # unrelated same-session member must never enter a signal
                # batch. Dynamic replacements are seeded by their marker-FD
                # identity and then followed through current child edges.
                cmux_queue_head = 1
                while (cmux_queue_head <= cmux_queue_tail) {
                  cmux_parent_pid = cmux_queue[cmux_queue_head++]
                  cmux_child_list = cmux_children[cmux_parent_pid]
                  if (cmux_child_list == "") continue
                  cmux_child_count = split(cmux_child_list, cmux_children_for_parent, /[[:space:]]+/)
                  for (cmux_index = 1; cmux_index <= cmux_child_count; cmux_index++) {
                    cmux_child_pid = cmux_children_for_parent[cmux_index]
                    if (cmux_child_pid == "" || cmux_child_pid in cmux_seen ||
                        cmux_state[cmux_child_pid] ~ /Z/) continue
                    cmux_seen[cmux_child_pid] = 1
                    cmux_depth[cmux_child_pid] = cmux_depth[cmux_parent_pid] + 1
                    cmux_queue[++cmux_queue_tail] = cmux_child_pid
                  }
                }
                for (cmux_pid in cmux_seen) {
                  print cmux_depth[cmux_pid], cmux_row[cmux_pid]
                }
              }
            ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_dynamic_members" \
              "$cmux_ssh_auth_snapshot" > "$cmux_ssh_auth_live"
          }

          cmux_ssh_auth_force_attempt=0
          cmux_ssh_auth_force_frozen=0
          cmux_ssh_auth_force_must_run=1
          while [ "$cmux_ssh_auth_force_attempt" -lt 32 ]; do
            if [ "$cmux_ssh_auth_force_must_run" != 1 ] && ! cmux_ssh_auth_cleanup_has_time; then
              break
            fi
            cmux_ssh_auth_force_must_run=0
            if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_owned; then
              cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
              break
            fi
            if [ ! -s "$cmux_ssh_auth_live" ]; then
              cmux_ssh_auth_force_frozen=1
              break
            fi
            if ! cmux_ssh_auth_filter_current_records \
              "$cmux_ssh_auth_live" "$cmux_ssh_auth_stop_candidates" 0; then
              cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
              break
            fi
            : > "$cmux_ssh_auth_pending"
            cmux_ssh_auth_signal_verified_batch STOP \
              "$cmux_ssh_auth_stop_candidates" "$cmux_ssh_auth_pending" || exit 0
            cmux_ssh_auth_append_pending || exit 0
            if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_owned; then
              cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
              break
            fi
            if /usr/bin/awk '
                FILENAME == ARGV[1] { cmux_owned[$2 SUBSEP $4 SUBSEP $6] = 1; next }
                $5 !~ /Z/ && ($2 SUBSEP $4 SUBSEP $6) in cmux_owned && $5 ~ /T/ { next }
                $5 !~ /Z/ { exit 1 }
              ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_live"; then
              cmux_ssh_auth_force_frozen=1
              break
            fi
            cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
            cmux_ssh_auth_force_attempt=$((cmux_ssh_auth_force_attempt + 1))
          done
          [ "$cmux_ssh_auth_force_frozen" = 1 ] || exit 0

          # `live` came from the confirming snapshot and contains only stable,
          # stopped identities. Do not fall back to a raw PID list if that
          # snapshot was unavailable.
          if ! cmux_ssh_auth_filter_current_records \
            "$cmux_ssh_auth_live" "$cmux_ssh_auth_kill_candidates" 1; then
            cmux_ssh_auth_resume_unconfirmed_stops "$cmux_ssh_auth_owned"
            exit 0
          fi
          cmux_ssh_auth_kill_failed=0
          cmux_ssh_auth_signal_verified_batch KILL \
            "$cmux_ssh_auth_kill_candidates" /dev/null || cmux_ssh_auth_kill_failed=1
          if [ "$cmux_ssh_auth_kill_failed" = 0 ] &&
             [ "$cmux_ssh_auth_dynamic_discovery_failed" = 0 ]; then
            cmux_ssh_auth_cleanup_complete=1
          else
            cmux_ssh_auth_cleanup_needs_root_abort=1
          fi
        )
        """#
    }

    /// Wraps a zsh command so status-255 failures become transient (254),
    /// unclassified (``unclassifiedFailureExitStatus``), or permanent (255).
    /// Every other exit status is preserved.
    ///
    /// The command runs under `script` so its standard streams remain attached
    /// to a PTY. A private FIFO receives a duplicate transcript while `sysread`
    /// emits 4 KiB records to an incremental classifier with a 128-byte
    /// cross-record carry. The classifier retains only a bounded result marker.
    /// A parent read/write descriptor prevents either FIFO endpoint from
    /// deadlocking if `script` fails before opening the transcript. Apple
    /// `script` already propagates the child status; its newer compatibility-only
    /// `-e` flag is intentionally omitted for macOS 14.
    /// This keeps interactive prompts visible and terminal-aware without
    /// allowing a noisy remote command to grow memory or a diagnostic file.
    /// Temporary state is removed on normal completion and signals.
    ///
    /// The command must contain only the foreground authentication attempt and
    /// its required preflight, lock, and cleanup work. Callers execute unrelated
    /// local commands after this wrapper returns so their statuses are not
    /// interpreted as SSH authentication failures.
    ///
    /// - Parameter command: Foreground authentication command to execute under zsh.
    /// - Returns: A zsh command suitable for embedding in a startup script.
    public func classifyingTransientFailure(in command: String) -> String {
        // `script` closes descriptors inherited from its launcher. Reopen the
        // per-attempt marker in the shell it starts, before replacing that
        // shell with the authentication command, so detached descendants keep
        // the ownership capability.
        let markerBootstrap = """
        if [ -n "${CMUX_SSH_AUTH_EVENT_TOKEN:-}" ]; then
          case "$CMUX_SSH_AUTH_EVENT_TOKEN" in
            ''|*[!A-Za-z0-9_-]*) ;;
            *)
              cmux_ssh_auth_marker_path="${TMPDIR:-/tmp}/cmux-ssh-auth-marker.$CMUX_SSH_AUTH_EVENT_TOKEN"
              if [ -f "$cmux_ssh_auth_marker_path" ]; then
                # zsh's managed descriptors are close-on-exec. Use a fixed
                # descriptor so the marker survives the nested env/zsh exec.
                if exec 7<> "$cmux_ssh_auth_marker_path" 2>/dev/null; then
                  # Unlink the marker after the inherited descriptor is open.
                  # The helper uses the saved device and inode, not this path.
                  /bin/rm -f -- "$cmux_ssh_auth_marker_path" 2>/dev/null || true
                fi
              fi
              ;;
          esac
        fi
        exec /usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command))
        """
        let nestedCommand = "/bin/zsh -fc \(shellQuote(markerBootstrap))"
        let classifierProgram = """
        {
          cmux_ssh_auth_line = tolower(cmux_ssh_auth_overlap $0)
          cmux_ssh_auth_transient_line = cmux_ssh_auth_line
          gsub(/connection closed by unknown port 65535/, "", cmux_ssh_auth_transient_line)
          gsub(/connection to unknown port 65535: broken pipe/, "", cmux_ssh_auth_transient_line)
          if (cmux_ssh_auth_line ~ cmux_ssh_auth_permanent_pattern) {
            print "permanent" > cmux_ssh_auth_classification
            close(cmux_ssh_auth_classification)
            cmux_ssh_auth_saw_permanent = 1
          } else if (!cmux_ssh_auth_saw_permanent && cmux_ssh_auth_transient_line ~ cmux_ssh_auth_transient_pattern) {
            print "transient" > cmux_ssh_auth_classification
            close(cmux_ssh_auth_classification)
          }
          if (length(cmux_ssh_auth_line) > 128) {
            cmux_ssh_auth_overlap = substr(cmux_ssh_auth_line, length(cmux_ssh_auth_line) - 127)
          } else {
            cmux_ssh_auth_overlap = cmux_ssh_auth_line
          }
        }
        """
        let markerSetup = """
        cmux_ssh_auth_marker_stat_command="$(command -v stat 2>/dev/null || true)"
        if [ -n "$cmux_ssh_auth_event_token" ]; then
          cmux_ssh_auth_term_event_fifo="${TMPDIR:-/tmp}/cmux-ssh-auth-term.$cmux_ssh_auth_event_token/done"
          cmux_ssh_auth_term_event_ack_fifo="${TMPDIR:-/tmp}/cmux-ssh-auth-term.$cmux_ssh_auth_event_token/ack"
          cmux_ssh_auth_marker_path="${TMPDIR:-/tmp}/cmux-ssh-auth-marker.$cmux_ssh_auth_event_token"
          cmux_ssh_auth_marker_identity_path="$cmux_ssh_auth_marker_path.identity"
          # Probe the host's stat implementation. GNU stat accepts -c and BSD
          # stat accepts -f; the first successful probe supplies numeric device
          # and inode values without assuming a platform-specific path.
          if ( set -C; : > "$cmux_ssh_auth_marker_path" ) 2>/dev/null; then
            if exec 7<> "$cmux_ssh_auth_marker_path" 2>/dev/null; then
              cmux_ssh_auth_marker_device=
              cmux_ssh_auth_marker_inode=
              if [ -n "$cmux_ssh_auth_marker_stat_command" ]; then
                cmux_ssh_auth_marker_device=$(
                  "$cmux_ssh_auth_marker_stat_command" -c '%d' "$cmux_ssh_auth_marker_path" 2>/dev/null ||
                  "$cmux_ssh_auth_marker_stat_command" -f '%d' "$cmux_ssh_auth_marker_path" 2>/dev/null ||
                  true
                )
                cmux_ssh_auth_marker_inode=$(
                  "$cmux_ssh_auth_marker_stat_command" -c '%i' "$cmux_ssh_auth_marker_path" 2>/dev/null ||
                  "$cmux_ssh_auth_marker_stat_command" -f '%i' "$cmux_ssh_auth_marker_path" 2>/dev/null ||
                  true
                )
              fi
              cmux_ssh_auth_marker_device_hex=$(printf '0x%x' "$cmux_ssh_auth_marker_device" 2>/dev/null || true)
              if case "$cmux_ssh_auth_marker_device:$cmux_ssh_auth_marker_inode" in
                ''|*[!0-9:]*|:*|*:) false ;;
                *) true ;;
              esac && [ -n "$cmux_ssh_auth_marker_device_hex" ] &&
                ( set -C; printf '%s %s %s\\n' "$cmux_ssh_auth_marker_device_hex" "$cmux_ssh_auth_marker_device" "$cmux_ssh_auth_marker_inode" > "$cmux_ssh_auth_marker_identity_path" ) 2>/dev/null; then
                cmux_ssh_auth_marker_owned=1
              else
                exec 7>&-
                /bin/rm -f -- "$cmux_ssh_auth_marker_path" "$cmux_ssh_auth_marker_identity_path" 2>/dev/null || true
              fi
            else
              /bin/rm -f -- "$cmux_ssh_auth_marker_path" 2>/dev/null || true
            fi
          fi
        fi
        """
        let script = [
            "umask 077",
            "cmux_ssh_auth_capture_state=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-auth.XXXXXX\") || exit 255",
            "cmux_ssh_auth_classifier_fifo=\"$cmux_ssh_auth_capture_state.classifier.fifo\"",
            "cmux_ssh_auth_classifier_guard_fd=",
            "cmux_ssh_auth_classifier_pid=",
            "cmux_ssh_auth_command_pid=",
            // The retry supervisor allocates a fresh nonce before launching
            // this classifier. It is shared with the cleanup helper through
            // the parent environment, so nested shells never derive an event
            // path from their unrelated `$$` values.
            "cmux_ssh_auth_event_token=\"${CMUX_SSH_AUTH_EVENT_TOKEN:-}\"",
            "case \"$cmux_ssh_auth_event_token\" in ''|*[!A-Za-z0-9_-]*) cmux_ssh_auth_event_token= ;; esac",
            "cmux_ssh_auth_term_event_fifo=; cmux_ssh_auth_term_event_ack_fifo=; cmux_ssh_auth_marker_path=; cmux_ssh_auth_marker_identity_path=; cmux_ssh_auth_marker_owned=0; cmux_ssh_auth_marker_cleanup_deferred=0",
            markerSetup,
            // Open both FIFO endpoints before waiting for the command. The
            // helper can then enter a bounded read without blocking on FIFO
            // setup, while the completion payload still has a happens-before
            // edge after the TERM handler exits.
            "cmux_ssh_auth_completion_event_fd=",
            "cmux_ssh_auth_completion_ack_fd=",
            "cmux_ssh_auth_completion_fds_open=0",
            "cmux_ssh_auth_prepare_signal_completion() { cmux_ssh_auth_completion_fds_open=0; if [ -n \"$cmux_ssh_auth_event_token\" ] && [ -p \"$cmux_ssh_auth_term_event_fifo\" ] && [ -p \"$cmux_ssh_auth_term_event_ack_fifo\" ] && exec {cmux_ssh_auth_completion_event_fd}<> \"$cmux_ssh_auth_term_event_fifo\" 2>/dev/null && exec {cmux_ssh_auth_completion_ack_fd}<> \"$cmux_ssh_auth_term_event_ack_fifo\" 2>/dev/null; then cmux_ssh_auth_completion_fds_open=1; else exec {cmux_ssh_auth_completion_event_fd}>&- 2>/dev/null || true; exec {cmux_ssh_auth_completion_ack_fd}>&- 2>/dev/null || true; cmux_ssh_auth_completion_event_fd=; cmux_ssh_auth_completion_ack_fd=; fi; }",
            // The cleanup helper creates the event FIFOs when cancellation
            // begins, after this wrapper has started. Retry the open at signal
            // completion so the normal startup race cannot disable the
            // completion handshake.
            "cmux_ssh_auth_signal_completion() { if [ \"$cmux_ssh_auth_completion_fds_open\" != 1 ]; then cmux_ssh_auth_prepare_signal_completion; fi; if [ \"$cmux_ssh_auth_completion_fds_open\" = 1 ]; then cmux_ssh_auth_marker_cleanup_deferred=1; printf '%s\\n' \"$cmux_ssh_auth_event_token\" >&$cmux_ssh_auth_completion_event_fd 2>/dev/null || true; cmux_ssh_auth_completion_ack=; IFS= read -r -t 2 cmux_ssh_auth_completion_ack <&$cmux_ssh_auth_completion_ack_fd || true; fi; if [ -n \"${cmux_ssh_auth_completion_event_fd:-}\" ]; then exec {cmux_ssh_auth_completion_event_fd}>&- 2>/dev/null || true; fi; if [ -n \"${cmux_ssh_auth_completion_ack_fd:-}\" ]; then exec {cmux_ssh_auth_completion_ack_fd}>&- 2>/dev/null || true; fi; cmux_ssh_auth_completion_event_fd=; cmux_ssh_auth_completion_ack_fd=; cmux_ssh_auth_completion_fds_open=0; }",
            "cmux_ssh_auth_capture_cleanup() {",
            "  if [ -n \"${cmux_ssh_auth_classifier_guard_fd:-}\" ]; then",
            "    exec {cmux_ssh_auth_classifier_guard_fd}>&-",
            "    cmux_ssh_auth_classifier_guard_fd=",
            "  fi",
            "  for cmux_ssh_auth_capture_pid in \"${cmux_ssh_auth_command_pid:-}\" \"${cmux_ssh_auth_classifier_pid:-}\"; do",
            "    if [ -n \"$cmux_ssh_auth_capture_pid\" ]; then",
            "      /bin/kill \"$cmux_ssh_auth_capture_pid\" >/dev/null 2>&1 || true",
            "      wait \"$cmux_ssh_auth_capture_pid\" 2>/dev/null || true",
            "    fi",
            "  done",
            "  if [ \"${cmux_ssh_auth_marker_owned:-0}\" = 1 ]; then exec 7>&-; if [ \"${cmux_ssh_auth_marker_cleanup_deferred:-0}\" != 1 ]; then /bin/rm -f -- \"$cmux_ssh_auth_marker_path\" \"$cmux_ssh_auth_marker_identity_path\" 2>/dev/null || true; fi; cmux_ssh_auth_marker_owned=0; fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_classifier_fifo\" \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_capture_signal_exit() {",
            "  cmux_ssh_auth_capture_signal_status=\"$1\"",
            "  cmux_ssh_auth_capture_signal_name=\"$2\"",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_command_pid:-}\" ]; then",
            "    cmux_ssh_auth_prepare_signal_completion",
            "    /bin/kill -\"$cmux_ssh_auth_capture_signal_name\" \"$cmux_ssh_auth_command_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_auth_command_pid\" 2>/dev/null || true",
            "    cmux_ssh_auth_command_pid=",
            "    cmux_ssh_auth_signal_completion",
            "  fi",
            "  cmux_ssh_auth_capture_cleanup",
            "  exit \"$cmux_ssh_auth_capture_signal_status\"",
            "}",
            "trap 'cmux_ssh_auth_capture_cleanup' EXIT",
            "trap 'cmux_ssh_auth_capture_signal_exit 129 HUP' HUP",
            "trap 'cmux_ssh_auth_capture_signal_exit 130 INT' INT",
            "trap 'cmux_ssh_auth_capture_signal_exit 143 TERM' TERM",
            "if ! /usr/bin/mkfifo \"$cmux_ssh_auth_classifier_fifo\"; then exit 255; fi",
            "exec {cmux_ssh_auth_classifier_guard_fd}<> \"$cmux_ssh_auth_classifier_fifo\" || exit 255",
            "( exec {cmux_ssh_auth_classifier_guard_fd}>&-; zmodload zsh/system || exit 255; exec {cmux_ssh_auth_classifier_fd}< \"$cmux_ssh_auth_classifier_fifo\" || exit 255; while sysread -i \"$cmux_ssh_auth_classifier_fd\" -s 4096 cmux_ssh_auth_classifier_chunk; do print -r -- \"$cmux_ssh_auth_classifier_chunk\"; done; exec {cmux_ssh_auth_classifier_fd}<&- ) | ( exec {cmux_ssh_auth_classifier_guard_fd}>&-; LC_ALL=C /usr/bin/awk -v cmux_ssh_auth_classification=\"$cmux_ssh_auth_capture_state\" -v cmux_ssh_auth_transient_pattern=\(shellQuote(transientFailurePattern)) -v cmux_ssh_auth_permanent_pattern=\(shellQuote(permanentFailurePattern)) \(shellQuote(classifierProgram)) ) &",
            "cmux_ssh_auth_classifier_pid=$!",
            // In event mode the helper must keep `script` alive until the
            // nested TERM handler publishes its completion marker. Ignore
            // only the helper's HUP/TERM signals in that mode; ordinary
            // wrappers retain their normal signal behavior.
            "( exec {cmux_ssh_auth_classifier_guard_fd}>&-; if [ -n \"$cmux_ssh_auth_event_token\" ]; then trap '' HUP TERM; fi; exec /usr/bin/script -q -F \"$cmux_ssh_auth_classifier_fifo\" \(nestedCommand) <&0 >&2 ) &",
            "cmux_ssh_auth_command_pid=$!",
            "wait \"$cmux_ssh_auth_command_pid\"",
            "cmux_ssh_auth_capture_status=$?",
            "cmux_ssh_auth_command_pid=",
            "exec {cmux_ssh_auth_classifier_guard_fd}>&-",
            "cmux_ssh_auth_classifier_guard_fd=",
            "wait \"$cmux_ssh_auth_classifier_pid\" 2>/dev/null || true",
            "cmux_ssh_auth_classifier_pid=",
            "if [ \"$cmux_ssh_auth_capture_status\" -eq 255 ]; then",
            "  case \"$(/bin/cat -- \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true)\" in",
            "    transient) cmux_ssh_auth_capture_status=254 ;;",
            "    permanent) ;;",
            "    *) cmux_ssh_auth_capture_status=\(unclassifiedFailureExitStatus) ;;",
            "  esac",
            "fi",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_auth_capture_cleanup",
            "exit \"$cmux_ssh_auth_capture_status\"",
        ].joined(separator: "\n")
        return "/bin/zsh -fc \(shellQuote(script))"
    }

    private func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
