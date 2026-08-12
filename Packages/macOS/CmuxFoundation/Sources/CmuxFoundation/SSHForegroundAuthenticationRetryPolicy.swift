internal import Foundation

/// Classifies foreground SSH authentication failures without hiding interactive
/// prompts or retrying permanent authentication and configuration errors.
///
/// OpenSSH uses status 255 for both transport outages and permanent failures.
/// The persistent PTY wrappers therefore need stderr context before deciding
/// whether an initial authentication attempt belongs in their reconnect loop.
public struct SSHForegroundAuthenticationRetryPolicy: Sendable {
    /// Exit status used only when the fixed recovery queue has no free slot.
    static let recoveryQueueCapacityStatus = 75

    /// One-second waits allowed while bounded recovery makes queue capacity.
    static let recoveryQueueCapacityRetryLimit = 8

    static let groupStateFileNames = [
        "identity",
        "identity.new",
        "created",
        "created.new",
        "publisher",
        "publisher.new",
        "rollback-only",
        "unpublished.root",
        "unpublished.root.new",
        "handoff-pending",
        "handoff-pending.new",
        "handoff.owner",
        "handoff.owner.new",
        "handoff.accepted",
        "handoff.failed",
        "handoff.failed.new",
        "anchor",
        "cancel",
        "cleanup.owner",
        "cleanup.owner.new",
        "processes",
        "processes.stopped",
        "owned",
        "owned.next",
        "groups",
        "groups.next",
        "groups.resume",
        "frozen",
        "individuals",
        "ordered",
        "signaled.groups",
        "signaled.pids",
        "reaper.failed",
        "reaper.failed.new",
        "orphaned",
        "orphaned.new",
    ]

    static let reaperLockStateFileNames = [
        "generation",
        "generation.new",
        "owner",
        "owner.new",
        "publisher",
        "publisher.new",
    ]

    static let cleanupLockStateFileNames = [
        "owner",
        "owner.new",
    ]

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

    /// Builds the shared creation, publication, and recovery handoff for one authentication group.
    ///
    /// The failure command runs before status 255 fallback handling and must
    /// preserve any entrypoint-specific pending signal. Recovery is scheduled
    /// only after the new directory is exported and present in the queue.
    ///
    /// Queue capacity starts up to eight signal-interruptible one-second recovery
    /// retries. These retries do not consume SSH authentication attempts. If the
    /// queue stays full, the caller's failure command ends startup instead of
    /// waiting without a bound.
    ///
    /// - Parameters:
    ///   - failureCommand: Trusted shell commands for non-capacity group-creation failure.
    ///   - capacityRetryInterruptionCondition: Trusted shell condition that becomes true
    ///     when the caller has received a signal while it waits for queue capacity.
    /// - Returns: A POSIX-shell snippet that creates and publishes the group.
    public func authenticationGroupCreationShellLine(
        failureCommand: String,
        capacityRetryInterruptionCondition: String
    ) -> String {
        """
        cmux_ssh_auth_group_creation_status=0
        cmux_ssh_auth_group_creation_retry=0
        while :; do
          CMUX_SSH_AUTH_GROUP_DIR=$(cmux_ssh_auth_create_group_dir)
          cmux_ssh_auth_group_creation_status=$?
          if [ "$cmux_ssh_auth_group_creation_status" -eq 0 ]; then break; fi
          if [ "$cmux_ssh_auth_group_creation_status" -ne \(Self.recoveryQueueCapacityStatus) ]; then break; fi
          if [ "$cmux_ssh_auth_group_creation_retry" -ge \(Self.recoveryQueueCapacityRetryLimit) ]; then break; fi
          cmux_ssh_schedule_failed_auth_group_recovery
          cmux_ssh_auth_group_creation_retry=$((cmux_ssh_auth_group_creation_retry + 1))
          sleep 1
          if \(capacityRetryInterruptionCondition); then
            cmux_ssh_auth_group_creation_status=1
            break
          fi
        done
        if [ "$cmux_ssh_auth_group_creation_status" -ne 0 ]; then \(failureCommand); fi
        unset cmux_ssh_auth_group_creation_status cmux_ssh_auth_group_creation_retry
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_schedule_failed_auth_group_recovery
        """
    }

    /// Builds the final removal command for a reaped authentication attempt's bounded state.
    ///
    /// Callers run this only after the authentication root has exited, when no late
    /// publisher can still require the cancellation marker.
    ///
    /// - Returns: A shell command that removes every file owned by the group-state protocol.
    public func processGroupStateRemovalShellCommand() -> String {
        let cleanupLockStateArguments = Self.cleanupLockStateFileNames
            .map { "\"$CMUX_SSH_AUTH_GROUP_DIR/cleanup.lock/\($0)\"" }
            .joined(separator: " ")
        let reaperLockStateArguments = Self.reaperLockStateFileNames
            .map { "\"$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock/\($0)\"" }
            .joined(separator: " ")
        return [
            "/bin/rm -f -- \(cleanupLockStateArguments) 2>/dev/null || true",
            "/bin/rmdir \"$CMUX_SSH_AUTH_GROUP_DIR/cleanup.lock\" 2>/dev/null || true",
            "/bin/rm -f -- \(reaperLockStateArguments) 2>/dev/null || true",
            "/bin/rmdir \"$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock\" 2>/dev/null || true",
            groupStateFileRemovalShellCommand(includingCancellationMarker: true),
        ].joined(separator: "; ")
    }

    /// Builds the shared cleanup body for one authentication group directory.
    ///
    /// The caller wraps this body in its entrypoint-specific shell function.
    /// Published process ownership is terminated before bounded state is removed,
    /// and a live reaper retains the directory until it finishes.
    ///
    /// - Parameter terminatesPublishedGroup: Whether this entrypoint runs foreground authentication.
    /// - Returns: A shell function body that consumes `CMUX_SSH_AUTH_GROUP_DIR`.
    public func authenticationGroupDirectoryCleanupShellBody(
        terminatesPublishedGroup: Bool
    ) -> String {
        let publishedCleanup = terminatesPublishedGroup
            ? publishedAuthenticationCleanupShellCommand()
            : ":"
        let recoveryEnqueue = "if { [ -s \"$CMUX_SSH_AUTH_GROUP_DIR/identity\" ] || [ -f \"$CMUX_SSH_AUTH_GROUP_DIR/rollback-only\" ] || [ -f \"$CMUX_SSH_AUTH_GROUP_DIR/handoff-pending\" ]; } && command -v cmux_ssh_auth_recovery_enqueue >/dev/null 2>&1; then cmux_ssh_auth_recovery_enqueue \"$CMUX_SSH_AUTH_GROUP_DIR\" || true; fi"
        let recoverySchedule = "if command -v cmux_ssh_schedule_failed_auth_group_recovery >/dev/null 2>&1; then cmux_ssh_schedule_failed_auth_group_recovery; fi"
        let liveHandoff = "{ command -v cmux_ssh_auth_recorded_process_is_live >/dev/null 2>&1 && cmux_ssh_auth_recorded_process_is_live \"$CMUX_SSH_AUTH_GROUP_DIR/handoff.owner\"; }"
        return "if [ -n \"${CMUX_SSH_AUTH_GROUP_DIR:-}\" ]; then \(publishedCleanup); if [ ! -s \"$CMUX_SSH_AUTH_GROUP_DIR/identity\" ] && [ ! -e \"$CMUX_SSH_AUTH_GROUP_DIR/cancel\" ] && [ ! -f \"$CMUX_SSH_AUTH_GROUP_DIR/rollback-only\" ] && [ ! -f \"$CMUX_SSH_AUTH_GROUP_DIR/handoff-pending\" ] && ! \(liveHandoff); then \(processGroupStateRemovalShellCommand()); /bin/rmdir \"$CMUX_SSH_AUTH_GROUP_DIR\" 2>/dev/null || true; fi; \(recoveryEnqueue); fi; CMUX_SSH_AUTH_GROUP_DIR=; export CMUX_SSH_AUTH_GROUP_DIR; \(recoverySchedule);"
    }

    private func publishedAuthenticationCleanupShellCommand() -> String {
        "if [ -s \"$CMUX_SSH_AUTH_GROUP_DIR/identity\" ]; then cmux_ssh_terminate_owned_auth_group; if [ -s \"$CMUX_SSH_AUTH_GROUP_DIR/identity\" ]; then cmux_ssh_launch_owned_auth_group_reaper \"$CMUX_SSH_AUTH_GROUP_DIR\"; fi; fi"
    }

    private func groupStateFileRemovalShellCommand(
        includingCancellationMarker: Bool
    ) -> String {
        let fileNames = Self.groupStateFileNames.filter {
            includingCancellationMarker || $0 != "cancel"
        }
        let arguments = fileNames
            .map { "\"$CMUX_SSH_AUTH_GROUP_DIR/\($0)\"" }
            .joined(separator: " ")
        return "/bin/rm -f -- \(arguments) 2>/dev/null || true"
    }

    func processIdentityShellFunctions() -> String {
        #"""
        cmux_ssh_auth_kernel_process_identity() {
          /usr/bin/perl -MTime::HiRes=alarm,time -e '
            use strict;
            use warnings;
            my $raw_pid = shift;
            my $raw_deadline_millis = shift;
            exit 1 unless defined($raw_pid) && $raw_pid =~ /\A[1-9][0-9]*\z/;
            my $deadline_active = 0;
            local $SIG{ALRM} = sub { exit 124 };
            if (defined($raw_deadline_millis) && length($raw_deadline_millis) > 0) {
              exit 1 unless $raw_deadline_millis =~ /\A[1-9][0-9]*\z/;
              my $remaining_millis = (0 + $raw_deadline_millis) - (time() * 1000);
              exit 124 if $remaining_millis <= 0;
              alarm($remaining_millis / 1000);
              $deadline_active = 1;
            }
            my $pid = 0 + $raw_pid;
            my $buffer = "\0" x 136;
            # Darwin SYS_proc_info(2), PROC_INFO_CALL_PIDINFO(2),
            # PROC_PIDTBSDINFO(3). MAXCOMLEN is 16, so twelve 4-byte fields,
            # pbi_comm[16], pbi_name[32], and pbi_nfiles[4] put pbi_pgid at
            # 100. The 136-byte structure ends with start time at 120/128.
            my $size = syscall(336, 2, $pid, 3, 0, $buffer, 136);
            exit 1 unless $size == 136;
            my $status = unpack("L<", substr($buffer, 4, 4));
            my $observed_pid = unpack("L<", substr($buffer, 12, 4));
            my $parent = unpack("L<", substr($buffer, 16, 4));
            my $group = unpack("L<", substr($buffer, 100, 4));
            my $seconds = unpack("Q<", substr($buffer, 120, 8));
            my $microseconds = unpack("Q<", substr($buffer, 128, 8));
            alarm(0) if $deadline_active;
            exit 1 if $observed_pid != $pid || $group == 0 ||
              $seconds == 0 || $microseconds >= 1_000_000 || $status == 5;
            print "$parent|$group|$status|K_${seconds}_${microseconds}\n";
          ' "$1" "${2:-}"
        }

        cmux_ssh_auth_identity() {
          cmux_ssh_auth_kernel_record=$(cmux_ssh_auth_kernel_process_identity \
            "$1" "${2:-}") || return $?
          cmux_ssh_auth_kernel_parent=${cmux_ssh_auth_kernel_record%%|*}
          cmux_ssh_auth_kernel_remainder=${cmux_ssh_auth_kernel_record#*|}
          cmux_ssh_auth_kernel_group=${cmux_ssh_auth_kernel_remainder%%|*}
          cmux_ssh_auth_kernel_remainder=${cmux_ssh_auth_kernel_remainder#*|}
          cmux_ssh_auth_kernel_status=${cmux_ssh_auth_kernel_remainder%%|*}
          cmux_ssh_auth_kernel_started=${cmux_ssh_auth_kernel_remainder#*|}
          case "$cmux_ssh_auth_kernel_parent:$cmux_ssh_auth_kernel_group:$cmux_ssh_auth_kernel_status" in
            *[!0-9:]*|:*|*:) return 1 ;;
          esac
          printf '%s|%s|%s\n' "$cmux_ssh_auth_kernel_parent" \
            "$cmux_ssh_auth_kernel_group" "$cmux_ssh_auth_kernel_started"
        }

        cmux_ssh_auth_stable_identity() {
          cmux_ssh_auth_full_identity=$(cmux_ssh_auth_identity \
            "$1" "${2:-}") || return $?
          cmux_ssh_auth_stable_remainder=${cmux_ssh_auth_full_identity#*|}
          if [ "$cmux_ssh_auth_stable_remainder" = \
            "$cmux_ssh_auth_full_identity" ]; then return 1; fi
          printf '%s\n' "$cmux_ssh_auth_stable_remainder"
        }

        cmux_ssh_auth_stopped_identity() {
          cmux_ssh_auth_kernel_record=$(cmux_ssh_auth_kernel_process_identity \
            "$1" "${2:-}") || return $?
          cmux_ssh_auth_kernel_parent=${cmux_ssh_auth_kernel_record%%|*}
          cmux_ssh_auth_kernel_remainder=${cmux_ssh_auth_kernel_record#*|}
          cmux_ssh_auth_kernel_group=${cmux_ssh_auth_kernel_remainder%%|*}
          cmux_ssh_auth_kernel_remainder=${cmux_ssh_auth_kernel_remainder#*|}
          cmux_ssh_auth_kernel_status=${cmux_ssh_auth_kernel_remainder%%|*}
          cmux_ssh_auth_kernel_started=${cmux_ssh_auth_kernel_remainder#*|}
          if [ "$cmux_ssh_auth_kernel_status" != 4 ]; then return 1; fi
          printf '%s|%s|%s\n' "$cmux_ssh_auth_kernel_parent" \
            "$cmux_ssh_auth_kernel_group" "$cmux_ssh_auth_kernel_started"
        }
        """#
    }

    private func recordedProcessLivenessShellFunctions() -> String {
        #"""
        cmux_ssh_auth_parse_recorded_process() {
          cmux_ssh_auth_record_file="$1"
          if [ ! -s "$cmux_ssh_auth_record_file" ]; then return 1; fi
          cmux_ssh_auth_record=$(/bin/cat -- "$cmux_ssh_auth_record_file" 2>/dev/null || true)
          CMUX_SSH_AUTH_RECORDED_GENERATION=
          case "$cmux_ssh_auth_record" in
            reaper-v1\|*)
              cmux_ssh_auth_record_payload=${cmux_ssh_auth_record#reaper-v1|}
              cmux_ssh_auth_record_generation=${cmux_ssh_auth_record_payload%%|*}
              cmux_ssh_auth_record=${cmux_ssh_auth_record_payload#*|}
              if [ "$cmux_ssh_auth_record" = "$cmux_ssh_auth_record_payload" ] || \
                [ "${#cmux_ssh_auth_record_generation}" -ne 32 ]; then return 1; fi
              case "$cmux_ssh_auth_record_generation" in
                *[!A-Fa-f0-9]*) return 1 ;;
              esac
              CMUX_SSH_AUTH_RECORDED_GENERATION="$cmux_ssh_auth_record_generation"
              ;;
          esac
          cmux_ssh_auth_record_pid=${cmux_ssh_auth_record%%|*}
          cmux_ssh_auth_record_identity=${cmux_ssh_auth_record#*|}
          if [ "$cmux_ssh_auth_record_identity" = "$cmux_ssh_auth_record" ]; then return 1; fi
          cmux_ssh_auth_record_first=${cmux_ssh_auth_record_identity%%|*}
          cmux_ssh_auth_record_remainder=${cmux_ssh_auth_record_identity#*|}
          if [ "$cmux_ssh_auth_record_remainder" = \
            "$cmux_ssh_auth_record_identity" ]; then return 1; fi
          case "$cmux_ssh_auth_record_remainder" in
            *'|'*)
              # Compatibility with records written before durable ownership
              # stopped including the reparentable PPID.
              cmux_ssh_auth_record_parent="$cmux_ssh_auth_record_first"
              cmux_ssh_auth_record_group=${cmux_ssh_auth_record_remainder%%|*}
              cmux_ssh_auth_record_started=${cmux_ssh_auth_record_remainder#*|}
              case "$cmux_ssh_auth_record_parent" in ''|*[!0-9]*) return 1 ;; esac
              ;;
            *)
              cmux_ssh_auth_record_group="$cmux_ssh_auth_record_first"
              cmux_ssh_auth_record_started="$cmux_ssh_auth_record_remainder"
              ;;
          esac
          case "$cmux_ssh_auth_record_pid" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_record_group" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_record_started" in ''|*[!A-Za-z0-9_:]*) return 1 ;; esac
          CMUX_SSH_AUTH_RECORDED_PID="$cmux_ssh_auth_record_pid"
          CMUX_SSH_AUTH_RECORDED_STABLE_IDENTITY="$cmux_ssh_auth_record_group|$cmux_ssh_auth_record_started"
        }

        cmux_ssh_auth_recorded_process_is_live() {
          cmux_ssh_auth_parse_recorded_process "$1" || return 1
          if cmux_ssh_auth_observed_identity=$(cmux_ssh_auth_stable_identity \
            "$CMUX_SSH_AUTH_RECORDED_PID"); then
            [ "$cmux_ssh_auth_observed_identity" = \
              "$CMUX_SSH_AUTH_RECORDED_STABLE_IDENTITY" ]
            return
          fi
          # A failed identity read is not proof that the owner exited. Refuse
          # reclamation while the PID remains live; a later pass can validate
          # the stable identity or observe its exit without creating two owners.
          cmux_ssh_auth_observed_state=$(/usr/bin/env LC_ALL=C LANG=C \
            /bin/ps -o state= -p "$CMUX_SSH_AUTH_RECORDED_PID" 2>/dev/null | \
            /usr/bin/tr -d '[:space:]')
          case "$cmux_ssh_auth_observed_state" in Z*) return 1 ;; esac
          /bin/kill -0 "$CMUX_SSH_AUTH_RECORDED_PID" 2>/dev/null
        }
        """#
    }

    /// Builds the bounded helper that terminates foreground SSH authentication.
    ///
    /// The classifier publishes a signal-resistant anchor in its isolated PTY
    /// process group. Cleanup validates the anchor and stable process identities,
    /// freezes the descendant closure in bounded batches, then KILLs each batch.
    /// The shared wrapper PID is KILLed only while its original identity still
    /// matches.
    ///
    /// - Returns: Shell functions that terminate the owned group and outer tree.
    public func processTreeTerminationShellFunction() -> String {
        #"""
        \#(processIdentityShellFunctions())

        \#(ownedProcessGroupTerminationShellFunctions())

        \#(recordedProcessLivenessShellFunctions())

        cmux_ssh_auth_kill_worker_if_identity_matches() {
          cmux_ssh_auth_worker_pid="$1"
          cmux_ssh_auth_worker_expected_identity="$2"
          case "$cmux_ssh_auth_worker_pid" in ''|0|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_worker_expected_identity" in
            ''|*[!A-Za-z0-9_:|]*) return 1 ;;
          esac
          cmux_ssh_auth_worker_current_identity=$(cmux_ssh_auth_stable_identity \
            "$cmux_ssh_auth_worker_pid") || return 1
          if [ "$cmux_ssh_auth_worker_current_identity" != \
            "$cmux_ssh_auth_worker_expected_identity" ]; then return 1; fi
          /bin/kill -KILL "$cmux_ssh_auth_worker_pid" >/dev/null 2>&1
        }

        cmux_ssh_wait_for_auth_process_exit() {
          cmux_ssh_auth_wait_pid="$1"
          case "$cmux_ssh_auth_wait_pid" in ''|0|*[!0-9]*) return 1 ;; esac
          cmux_ssh_auth_wait_started="$(cmux_ssh_auth_now_millis)" || return 1
          case "$cmux_ssh_auth_wait_started" in ''|*[!0-9]*) return 1 ;; esac
          cmux_ssh_auth_wait_deadline=$((cmux_ssh_auth_wait_started + 500))
          while /bin/kill -0 "$cmux_ssh_auth_wait_pid" 2>/dev/null; do
            cmux_ssh_auth_wait_state=$(/usr/bin/env LC_ALL=C LANG=C \
              /bin/ps -o state= -p "$cmux_ssh_auth_wait_pid" 2>/dev/null | \
              /usr/bin/tr -d '[:space:]')
            case "$cmux_ssh_auth_wait_state" in Z*) break ;; esac
            cmux_ssh_auth_wait_now="$(cmux_ssh_auth_now_millis)" || return 1
            case "$cmux_ssh_auth_wait_now" in ''|*[!0-9]*) return 1 ;; esac
            if [ "$cmux_ssh_auth_wait_now" -ge \
              "$cmux_ssh_auth_wait_deadline" ]; then return 1; fi
            /bin/sleep 0.01
          done
          wait "$cmux_ssh_auth_wait_pid" 2>/dev/null || true
          return 0
        }

        cmux_ssh_auth_publish_current_worker() {
          cmux_ssh_auth_worker_file="$1"
          if ! /bin/sh -c '
            cmux_owner_pid=$PPID
            cmux_owner_record=$(/usr/bin/perl -e '\''
              use strict;
              use warnings;
              my $raw_pid = shift;
              exit 1 unless defined($raw_pid) && $raw_pid =~ /\A[1-9][0-9]*\z/;
              my $pid = 0 + $raw_pid;
              my $buffer = "\0" x 136;
              my $size = syscall(336, 2, $pid, 3, 0, $buffer, 136);
              exit 1 unless $size == 136;
              my $status = unpack("L<", substr($buffer, 4, 4));
              my $observed_pid = unpack("L<", substr($buffer, 12, 4));
              my $group = unpack("L<", substr($buffer, 100, 4));
              my $seconds = unpack("Q<", substr($buffer, 120, 8));
              my $microseconds = unpack("Q<", substr($buffer, 128, 8));
              exit 1 if $observed_pid != $pid || $group == 0 ||
                $seconds == 0 || $microseconds >= 1_000_000 || $status == 5;
              print "$group|K_${seconds}_${microseconds}\n";
            '\'' "$cmux_owner_pid")
            cmux_owner_identity="$cmux_owner_record"
            if [ -z "$cmux_owner_identity" ]; then exit 1; fi
            umask 077
            printf "%s|%s\n" "$cmux_owner_pid" "$cmux_owner_identity" > "$1"
          ' cmux-worker-owner "$cmux_ssh_auth_worker_file.new" \
            2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_worker_file.new" \
              "$cmux_ssh_auth_worker_file" 2>/dev/null; then
            /bin/rm -f -- "$cmux_ssh_auth_worker_file.new" 2>/dev/null || true
            return 1
          fi
        }

        cmux_ssh_auth_reaper_generation_is_current() {
          cmux_ssh_auth_generation_lock="$1"
          cmux_ssh_auth_expected_generation="$2"
          cmux_ssh_auth_observed_generation=$(/bin/cat -- \
            "$cmux_ssh_auth_generation_lock/generation" 2>/dev/null || true)
          [ "$cmux_ssh_auth_observed_generation" = \
            "$cmux_ssh_auth_expected_generation" ]
        }

        cmux_ssh_auth_reaper_owner_matches_generation() {
          cmux_ssh_auth_generation_lock="$1"
          cmux_ssh_auth_expected_generation="$2"
          cmux_ssh_auth_parse_recorded_process \
            "$cmux_ssh_auth_generation_lock/owner" || return 1
          [ "$CMUX_SSH_AUTH_RECORDED_GENERATION" = \
            "$cmux_ssh_auth_expected_generation" ] || return 1
          cmux_ssh_auth_reaper_observed_identity=$(cmux_ssh_auth_stable_identity \
            "$CMUX_SSH_AUTH_RECORDED_PID") || return 1
          [ "$cmux_ssh_auth_reaper_observed_identity" = \
            "$CMUX_SSH_AUTH_RECORDED_STABLE_IDENTITY" ]
        }

        cmux_ssh_auth_group_cleanup_is_abandoned() {
          cmux_ssh_auth_cleanup_group_dir="$1"
          if [ ! -e "$cmux_ssh_auth_cleanup_group_dir/cancel" ]; then return 1; fi
          for cmux_ssh_auth_cleanup_record_file in \
            "$cmux_ssh_auth_cleanup_group_dir/cleanup.lock/owner" \
            "$cmux_ssh_auth_cleanup_group_dir/cleanup.lock/owner.new" \
            "$cmux_ssh_auth_cleanup_group_dir/cleanup.owner" \
            "$cmux_ssh_auth_cleanup_group_dir/cleanup.owner.new"; do
            if [ -s "$cmux_ssh_auth_cleanup_record_file" ]; then break; fi
          done
          if [ ! -s "$cmux_ssh_auth_cleanup_record_file" ]; then return 0; fi
          cmux_ssh_auth_parse_recorded_process "$cmux_ssh_auth_cleanup_record_file" || return 1
          if ! cmux_ssh_auth_cleanup_observed_identity=$(cmux_ssh_auth_stable_identity \
            "$CMUX_SSH_AUTH_RECORDED_PID"); then
            if /bin/kill -0 "$CMUX_SSH_AUTH_RECORDED_PID" 2>/dev/null; then
              return 1
            fi
            return 0
          fi
          [ "$cmux_ssh_auth_cleanup_observed_identity" != \
            "$CMUX_SSH_AUTH_RECORDED_STABLE_IDENTITY" ]
        }

        cmux_ssh_auth_group_publisher_is_live() {
          cmux_ssh_auth_publisher_group_dir="$1"
          if cmux_ssh_auth_recorded_process_is_live \
            "$cmux_ssh_auth_publisher_group_dir/cleanup.lock/owner" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/cleanup.lock/owner.new" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/cleanup.owner" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/cleanup.owner.new" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/handoff.owner" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/handoff.owner.new" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/publisher" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_publisher_group_dir/publisher.new"; then
            return 0
          fi
          # The anchor's current parent is not a publisher identity. A durable
          # publisher or cleanup-owner record is the only liveness proof.
          return 1
        }

        cmux_ssh_auth_reclaim_stale_reaper_lock() {
          cmux_ssh_auth_stale_lock="$1"
          if [ ! -d "$cmux_ssh_auth_stale_lock" ]; then return 0; fi
          if cmux_ssh_auth_recorded_process_is_live "$cmux_ssh_auth_stale_lock/owner" || \
            cmux_ssh_auth_recorded_process_is_live "$cmux_ssh_auth_stale_lock/publisher"; then
            return 1
          fi
          /bin/rm -f -- "$cmux_ssh_auth_stale_lock/owner" \
            "$cmux_ssh_auth_stale_lock/owner.new" \
            "$cmux_ssh_auth_stale_lock/publisher" \
            "$cmux_ssh_auth_stale_lock/publisher.new" \
            "$cmux_ssh_auth_stale_lock/generation" \
            "$cmux_ssh_auth_stale_lock/generation.new" \
            "$cmux_ssh_auth_stale_lock/pending" \
            "$cmux_ssh_auth_stale_lock/pending.new" 2>/dev/null || true
          /bin/rmdir "$cmux_ssh_auth_stale_lock" 2>/dev/null
        }

        cmux_ssh_auth_group_anchor_is_live() {
          cmux_ssh_auth_anchor_group_dir="$1"
          cmux_ssh_auth_anchor_record=$(/bin/cat -- \
            "$cmux_ssh_auth_anchor_group_dir/identity" 2>/dev/null || true)
          cmux_ssh_auth_anchor_pid=${cmux_ssh_auth_anchor_record%%|*}
          cmux_ssh_auth_anchor_remainder=${cmux_ssh_auth_anchor_record#*|}
          cmux_ssh_auth_anchor_group=${cmux_ssh_auth_anchor_remainder%%|*}
          cmux_ssh_auth_anchor_started=${cmux_ssh_auth_anchor_remainder#*|}
          case "$cmux_ssh_auth_anchor_pid" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_anchor_group" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_anchor_started" in ''|*[!A-Za-z0-9_:]*) return 1 ;; esac
          cmux_ssh_auth_anchor_identity=$(cmux_ssh_auth_identity \
            "$cmux_ssh_auth_anchor_pid")
          cmux_ssh_auth_anchor_observed_remainder=${cmux_ssh_auth_anchor_identity#*|}
          cmux_ssh_auth_anchor_observed_group=${cmux_ssh_auth_anchor_observed_remainder%%|*}
          cmux_ssh_auth_anchor_observed_started=${cmux_ssh_auth_anchor_observed_remainder#*|}
          [ "$cmux_ssh_auth_anchor_observed_group" = "$cmux_ssh_auth_anchor_group" ] && \
            [ "$cmux_ssh_auth_anchor_observed_started" = "$cmux_ssh_auth_anchor_started" ]
        }

        cmux_ssh_auth_group_orphan_retention_expired() {
          # Never signal an unverifiable PID or process group: it may have been
          # reused. Quarantine the bounded ownership record from the first
          # confirmed publisher-and-anchor absence, then reclaim it after one day.
          cmux_ssh_auth_orphan_group_dir="$1"
          cmux_ssh_auth_orphan_now=$(/bin/date +%s 2>/dev/null || true)
          cmux_ssh_auth_orphaned_at=$(/bin/cat -- \
            "$cmux_ssh_auth_orphan_group_dir/orphaned" 2>/dev/null || true)
          case "$cmux_ssh_auth_orphan_now" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_orphaned_at" in ''|*[!0-9]*)
            cmux_ssh_auth_orphaned_at=
            ;;
          esac
          if [ "${#cmux_ssh_auth_orphaned_at}" -gt 12 ]; then
            cmux_ssh_auth_orphaned_at=
          elif [ -n "$cmux_ssh_auth_orphaned_at" ] && \
            [ "$cmux_ssh_auth_orphaned_at" -gt "$cmux_ssh_auth_orphan_now" ]; then
            cmux_ssh_auth_orphaned_at=
          fi
          if [ -z "$cmux_ssh_auth_orphaned_at" ]; then
            (umask 077; printf '%s\n' "$cmux_ssh_auth_orphan_now" \
              > "$cmux_ssh_auth_orphan_group_dir/orphaned.new") 2>/dev/null && \
              /bin/mv -f -- "$cmux_ssh_auth_orphan_group_dir/orphaned.new" \
                "$cmux_ssh_auth_orphan_group_dir/orphaned" 2>/dev/null || true
            return 1
          fi
          [ $((cmux_ssh_auth_orphan_now - cmux_ssh_auth_orphaned_at)) -ge 86400 ]
        }

        cmux_ssh_auth_recover_expired_orphan() (
          cmux_ssh_auth_orphan_group_dir="$1"
          cmux_ssh_auth_expected_dir_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_orphan_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_observed_dir_identity" != \
            "$cmux_ssh_auth_expected_dir_identity" ]; then return 1; fi
          for cmux_ssh_auth_orphan_state in identity cancel cleanup.owner \
            cleanup.owner.new processes processes.stopped owned owned.next groups \
            groups.next groups.resume frozen individuals ordered signaled.groups \
            signaled.pids; do
            if [ -L "$cmux_ssh_auth_orphan_group_dir/$cmux_ssh_auth_orphan_state" ]; then
              return 1
            fi
          done
          if [ -L "$cmux_ssh_auth_orphan_group_dir/cleanup.lock" ] || \
            [ -L "$cmux_ssh_auth_orphan_group_dir/reaper.lock" ]; then return 1; fi
          cmux_ssh_auth_orphan_identity=$(/bin/cat -- \
            "$cmux_ssh_auth_orphan_group_dir/identity" 2>/dev/null || true)
          cmux_ssh_auth_orphan_anchor=${cmux_ssh_auth_orphan_identity%%|*}
          cmux_ssh_auth_orphan_remainder=${cmux_ssh_auth_orphan_identity#*|}
          cmux_ssh_auth_orphan_group=${cmux_ssh_auth_orphan_remainder%%|*}
          cmux_ssh_auth_orphan_started=${cmux_ssh_auth_orphan_remainder#*|}
          case "$cmux_ssh_auth_orphan_anchor:$cmux_ssh_auth_orphan_group:$cmux_ssh_auth_orphan_started" in
            *[!A-Za-z0-9_:]*|:*|*:) return 1 ;;
          esac
          if cmux_ssh_auth_group_publisher_is_live \
            "$cmux_ssh_auth_orphan_group_dir" || \
            cmux_ssh_auth_group_anchor_is_live \
              "$cmux_ssh_auth_orphan_group_dir"; then return 1; fi

          cmux_ssh_auth_cleanup_owner_file="$cmux_ssh_auth_orphan_group_dir/cleanup.owner"
          cmux_ssh_auth_cleanup_owner_publish_file="$cmux_ssh_auth_orphan_group_dir/cleanup.owner.new"
          cmux_ssh_auth_cleanup_lock="$cmux_ssh_auth_orphan_group_dir/cleanup.lock"
          cmux_ssh_auth_cleanup_lock_owner_file="$cmux_ssh_auth_cleanup_lock/owner"
          cmux_ssh_auth_cleanup_lock_owner_publish_file="$cmux_ssh_auth_cleanup_lock/owner.new"
          cmux_ssh_auth_process_snapshot="$cmux_ssh_auth_orphan_group_dir/processes"
          cmux_ssh_auth_poststop_snapshot="$cmux_ssh_auth_orphan_group_dir/processes.stopped"
          cmux_ssh_auth_owned_processes="$cmux_ssh_auth_orphan_group_dir/owned"
          cmux_ssh_auth_next_owned_processes="$cmux_ssh_auth_orphan_group_dir/owned.next"
          cmux_ssh_auth_owned_groups="$cmux_ssh_auth_orphan_group_dir/groups"
          cmux_ssh_auth_next_owned_groups="$cmux_ssh_auth_orphan_group_dir/groups.next"
          cmux_ssh_auth_resume_groups="$cmux_ssh_auth_orphan_group_dir/groups.resume"
          cmux_ssh_auth_frozen_processes="$cmux_ssh_auth_orphan_group_dir/frozen"
          cmux_ssh_auth_individual_processes="$cmux_ssh_auth_orphan_group_dir/individuals"
          cmux_ssh_auth_ordered_processes="$cmux_ssh_auth_orphan_group_dir/ordered"
          cmux_ssh_auth_signaled_groups="$cmux_ssh_auth_orphan_group_dir/signaled.groups"
          cmux_ssh_auth_signaled_processes="$cmux_ssh_auth_orphan_group_dir/signaled.pids"
          cmux_ssh_auth_orphan_now=$(cmux_ssh_auth_now_millis) || return 1
          case "$cmux_ssh_auth_orphan_now" in ''|*[!0-9]*) return 1 ;; esac
          cmux_ssh_auth_deadline_millis=$((cmux_ssh_auth_orphan_now + 500))
          cmux_ssh_auth_hard_deadline_millis=$((cmux_ssh_auth_orphan_now + 2000))
          cmux_ssh_auth_orphan_transaction_complete=0
          CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD=
          cmux_ssh_auth_orphan_cleanup() {
            if [ "$cmux_ssh_auth_orphan_transaction_complete" != 1 ]; then
              cmux_ssh_auth_deadline_millis="${cmux_ssh_auth_hard_deadline_millis:-0}"
              cmux_ssh_auth_resume_signaled_processes >/dev/null 2>&1 || true
            fi
            cmux_ssh_auth_cleanup_claim_release
          }
          trap 'cmux_ssh_auth_orphan_cleanup' EXIT
          cmux_ssh_auth_cleanup_claim || return 1
          cmux_ssh_auth_cleanup_claim_is_current || return 1
          cmux_ssh_auth_claimed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_orphan_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_claimed_dir_identity" != \
            "$cmux_ssh_auth_expected_dir_identity" ]; then return 1; fi
          cmux_ssh_auth_claimed_group_identity=$(/bin/cat -- \
            "$cmux_ssh_auth_orphan_group_dir/identity" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_claimed_group_identity" != \
            "$cmux_ssh_auth_orphan_identity" ]; then return 1; fi
          : > "$cmux_ssh_auth_orphan_group_dir/cancel" 2>/dev/null || return 1
          cmux_ssh_auth_owned_group=0
          # A detached POSIX subshell can retain the launcher's $$ after that
          # process exits. Do not make orphan recovery depend on that stale PID.
          # Group selection still requires every live member to match a stable
          # owned identity, so zero safely disables only the caller exclusion.
          cmux_ssh_auth_caller_group=0
          if [ ! -e "$cmux_ssh_auth_owned_processes" ]; then
            : > "$cmux_ssh_auth_owned_processes" || return 1
          fi
          cmux_ssh_auth_run_cleanup_transactions || return 1
          cmux_ssh_auth_orphan_transaction_complete=1
          cmux_ssh_auth_cleanup_claim_is_current || return 1
          cmux_ssh_auth_reclaim_stale_reaper_lock \
            "$cmux_ssh_auth_orphan_group_dir/reaper.lock" || return 1
          CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_orphan_group_dir"
          export CMUX_SSH_AUTH_GROUP_DIR
          \#(groupStateFileRemovalShellCommand(includingCancellationMarker: false))
          cmux_ssh_auth_cleanup_claim_release
          /bin/rm -f -- "$cmux_ssh_auth_orphan_group_dir/cancel" 2>/dev/null || true
          /bin/rmdir "$cmux_ssh_auth_orphan_group_dir" 2>/dev/null
        )

        cmux_ssh_auth_group_creation_retention_expired() {
          cmux_ssh_auth_created_group_dir="$1"
          cmux_ssh_auth_created_now=$(/bin/date +%s 2>/dev/null || true)
          cmux_ssh_auth_created_at=$(/bin/cat -- \
            "$cmux_ssh_auth_created_group_dir/created" 2>/dev/null || true)
          case "$cmux_ssh_auth_created_now" in ''|*[!0-9]*) return 1 ;; esac
          case "$cmux_ssh_auth_created_at" in ''|*[!0-9]*)
            cmux_ssh_auth_created_at=
            ;;
          esac
          if [ "${#cmux_ssh_auth_created_at}" -gt 12 ]; then
            cmux_ssh_auth_created_at=
          elif [ -n "$cmux_ssh_auth_created_at" ] && \
            [ "$cmux_ssh_auth_created_at" -gt "$cmux_ssh_auth_created_now" ]; then
            cmux_ssh_auth_created_at=
          fi
          if [ -z "$cmux_ssh_auth_created_at" ]; then
            (umask 077; printf '%s\n' "$cmux_ssh_auth_created_now" \
              > "$cmux_ssh_auth_created_group_dir/created.new") 2>/dev/null && \
              /bin/mv -f -- "$cmux_ssh_auth_created_group_dir/created.new" \
                "$cmux_ssh_auth_created_group_dir/created" 2>/dev/null || true
            return 1
          fi
          [ $((cmux_ssh_auth_created_now - cmux_ssh_auth_created_at)) -ge 86400 ]
        }

        cmux_ssh_launch_owned_auth_group_reaper() {
          CMUX_SSH_AUTH_REAPER_LAUNCHED=0
          cmux_ssh_auth_reaper_group_dir="$1"
          cmux_ssh_auth_reaper_generation=$(/usr/bin/uuidgen 2>/dev/null | \
            /usr/bin/awk '{ gsub(/-/, ""); print }')
          if [ "${#cmux_ssh_auth_reaper_generation}" -ne 32 ]; then return 0; fi
          case "$cmux_ssh_auth_reaper_generation" in
            *[!A-Fa-f0-9]*) return 0 ;;
          esac
          cmux_ssh_auth_reaper_expected_dir_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_reaper_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_reaper_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_reaper_observed_dir_identity" != \
            "$cmux_ssh_auth_reaper_expected_dir_identity" ]; then return 0; fi
          if [ ! -s "$cmux_ssh_auth_reaper_group_dir/identity" ]; then return 0; fi
          cmux_ssh_auth_reaper_lock="$cmux_ssh_auth_reaper_group_dir/reaper.lock"
          # Serialize the mkdir-to-publisher transition under the durable
          # recovery lock. A second launcher must not classify the creator's
          # fresh, still-empty directory as stale before ownership is published.
          cmux_ssh_auth_recovery_lock || return 0
          if ! /bin/mkdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null; then
            cmux_ssh_auth_reclaim_stale_reaper_lock "$cmux_ssh_auth_reaper_lock" || {
              cmux_ssh_auth_recovery_unlock
              return 0
            }
            /bin/mkdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || {
              cmux_ssh_auth_recovery_unlock
              return 0
            }
          fi
          if ! printf '%s\n' "$cmux_ssh_auth_reaper_generation" \
              > "$cmux_ssh_auth_reaper_lock/generation.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_reaper_lock/generation.new" \
              "$cmux_ssh_auth_reaper_lock/generation" 2>/dev/null; then
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/generation" \
              "$cmux_ssh_auth_reaper_lock/generation.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          # This function can run in a long-lived recovery subshell after the
          # startup shell has exited. POSIX shells retain the startup shell's
          # `$$` in that subshell, so publish and inspect the current worker.
          if ! cmux_ssh_auth_publish_current_worker \
              "$cmux_ssh_auth_reaper_lock/publisher"; then
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher.new" \
              "$cmux_ssh_auth_reaper_lock/generation" \
              "$cmux_ssh_auth_reaper_lock/generation.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          if ! cmux_ssh_auth_parse_recorded_process \
              "$cmux_ssh_auth_reaper_lock/publisher"; then
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" \
              "$cmux_ssh_auth_reaper_lock/publisher.new" \
              "$cmux_ssh_auth_reaper_lock/generation" \
              "$cmux_ssh_auth_reaper_lock/generation.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          cmux_ssh_auth_reaper_publisher_record=$(/bin/cat -- \
            "$cmux_ssh_auth_reaper_lock/publisher" 2>/dev/null || true)
          cmux_ssh_auth_reaper_publisher_pid="$CMUX_SSH_AUTH_RECORDED_PID"
          cmux_ssh_auth_reaper_caller_group=$(/usr/bin/env LC_ALL=C LANG=C \
            /bin/ps -o pgid= -p "$cmux_ssh_auth_reaper_publisher_pid" \
              2>/dev/null | /usr/bin/tr -d '[:space:]')
          case "$cmux_ssh_auth_reaper_caller_group" in
            ''|*[!0-9]*)
              /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" \
                "$cmux_ssh_auth_reaper_lock/publisher.new" \
                "$cmux_ssh_auth_reaper_lock/generation" \
                "$cmux_ssh_auth_reaper_lock/generation.new" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
              cmux_ssh_auth_recovery_unlock
              return 0
              ;;
          esac
          # Every SSH startup shares these durable slots. The slot publisher
          # closes the mkdir-to-owner gap, then the reaper holds the slot with
          # its precise process identity until cleanup exits.
          cmux_ssh_auth_reaper_slot=
          cmux_ssh_auth_reaper_slot_index=0
          while [ "$cmux_ssh_auth_reaper_slot_index" -lt 8 ]; do
            cmux_ssh_auth_reaper_slot_candidate="$cmux_ssh_auth_recovery_root/active.$cmux_ssh_auth_reaper_slot_index"
            if /bin/mkdir "$cmux_ssh_auth_reaper_slot_candidate" 2>/dev/null; then
              cmux_ssh_auth_reaper_slot="$cmux_ssh_auth_reaper_slot_candidate"
              break
            fi
            if cmux_ssh_auth_reclaim_stale_reaper_lock \
                "$cmux_ssh_auth_reaper_slot_candidate" && \
              /bin/mkdir "$cmux_ssh_auth_reaper_slot_candidate" 2>/dev/null; then
              cmux_ssh_auth_reaper_slot="$cmux_ssh_auth_reaper_slot_candidate"
              break
            fi
            cmux_ssh_auth_reaper_slot_index=$((cmux_ssh_auth_reaper_slot_index + 1))
          done
          if [ -z "$cmux_ssh_auth_reaper_slot" ]; then
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" \
              "$cmux_ssh_auth_reaper_lock/publisher.new" \
              "$cmux_ssh_auth_reaper_lock/generation" \
              "$cmux_ssh_auth_reaper_lock/generation.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          if ! printf '%s\n' "$cmux_ssh_auth_reaper_generation" \
              > "$cmux_ssh_auth_reaper_slot/generation.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_reaper_slot/generation.new" \
              "$cmux_ssh_auth_reaper_slot/generation" 2>/dev/null || ! \
            printf '%s\n' "$cmux_ssh_auth_reaper_publisher_record" \
              > "$cmux_ssh_auth_reaper_slot/publisher.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_reaper_slot/publisher.new" \
              "$cmux_ssh_auth_reaper_slot/publisher" 2>/dev/null; then
            /bin/rm -f -- "$cmux_ssh_auth_reaper_slot/publisher" \
              "$cmux_ssh_auth_reaper_slot/publisher.new" \
              "$cmux_ssh_auth_reaper_slot/generation" \
              "$cmux_ssh_auth_reaper_slot/generation.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_slot" 2>/dev/null || true
            /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" \
              "$cmux_ssh_auth_reaper_lock/publisher.new" \
              "$cmux_ssh_auth_reaper_lock/generation" \
              "$cmux_ssh_auth_reaper_lock/generation.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          cmux_ssh_auth_recovery_unlock
          printf 'cleanup-pending\n' \
            > "$cmux_ssh_auth_reaper_group_dir/reaper.failed.new" 2>/dev/null || {
              cmux_ssh_auth_release_reaper_lock_if_current \
                "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" 0
              cmux_ssh_auth_release_reaper_lock_if_current \
                "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation" 0
              return 0
            }
          /bin/mv -f -- "$cmux_ssh_auth_reaper_group_dir/reaper.failed.new" \
            "$cmux_ssh_auth_reaper_group_dir/reaper.failed" 2>/dev/null || {
              cmux_ssh_auth_release_reaper_lock_if_current \
                "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" 0
              cmux_ssh_auth_release_reaper_lock_if_current \
                "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation" 0
              return 0
            }
          (
            trap '' HUP INT TERM
            CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_reaper_group_dir"
            export CMUX_SSH_AUTH_GROUP_DIR
            cmux_ssh_auth_reaper_owner_attempt=0
            while { [ ! -s "$cmux_ssh_auth_reaper_lock/owner" ] || \
              [ ! -s "$cmux_ssh_auth_reaper_slot/owner" ]; } && \
              [ "$cmux_ssh_auth_reaper_owner_attempt" -lt 100 ]; do
              /bin/sleep 0.01
              cmux_ssh_auth_reaper_owner_attempt=$((cmux_ssh_auth_reaper_owner_attempt + 1))
            done
            if [ ! -s "$cmux_ssh_auth_reaper_lock/owner" ] || \
              [ ! -s "$cmux_ssh_auth_reaper_slot/owner" ]; then
              exit 0
            fi
            if ! cmux_ssh_auth_reaper_generation_is_current \
                "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" || ! \
              cmux_ssh_auth_reaper_owner_matches_generation \
                "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" || ! \
              cmux_ssh_auth_reaper_generation_is_current \
                "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation" || ! \
              cmux_ssh_auth_reaper_owner_matches_generation \
                "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation"; then
              exit 0
            fi
            cmux_ssh_auth_reaper_attempt=0
            cmux_ssh_auth_reaper_delay=1
            while [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ] && \
              [ "$cmux_ssh_auth_reaper_attempt" -lt 3 ]; do
              cmux_ssh_auth_reaper_attempt=$((cmux_ssh_auth_reaper_attempt + 1))
              cmux_ssh_terminate_owned_auth_group "$cmux_ssh_auth_reaper_caller_group"
              if [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then break; fi
              if [ "$cmux_ssh_auth_reaper_attempt" -lt 3 ]; then
                /bin/sleep "$cmux_ssh_auth_reaper_delay"
                cmux_ssh_auth_reaper_delay=$((cmux_ssh_auth_reaper_delay * 2))
              fi
            done
            if [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
              printf 'cleanup-incomplete attempts=%s\n' "$cmux_ssh_auth_reaper_attempt" \
                > "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed.new" 2>/dev/null || true
              /bin/mv -f -- "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed.new" \
                "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed" 2>/dev/null || true
              /usr/bin/logger -t cmux \
                "SSH authentication cleanup deferred: $CMUX_SSH_AUTH_GROUP_DIR" \
                >/dev/null 2>&1 || true
            else
              /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed" \
                "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed.new" 2>/dev/null || true
            fi
            CMUX_SSH_AUTH_REAPER_RELEASED=0
            cmux_ssh_auth_release_reaper_lock_if_current \
              "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" 1
            cmux_ssh_auth_reaper_group_lock_released="$CMUX_SSH_AUTH_REAPER_RELEASED"
            cmux_ssh_auth_release_reaper_lock_if_current \
              "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation" 1
            if [ "$cmux_ssh_auth_reaper_group_lock_released" = 1 ] && \
              [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
              \#(groupStateFileRemovalShellCommand(includingCancellationMarker: true))
              /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true
            fi
          ) </dev/null >/dev/null 2>&1 &
          cmux_ssh_auth_reaper_pid=$!
          cmux_ssh_auth_reaper_identity=$(cmux_ssh_auth_stable_identity \
            "$cmux_ssh_auth_reaper_pid")
          cmux_ssh_auth_reaper_owner_record="reaper-v1|$cmux_ssh_auth_reaper_generation|$cmux_ssh_auth_reaper_pid|$cmux_ssh_auth_reaper_identity"
          if [ -z "$cmux_ssh_auth_reaper_identity" ] || ! \
            cmux_ssh_auth_reaper_generation_is_current \
              "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" || ! \
            cmux_ssh_auth_reaper_generation_is_current \
              "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation" || ! \
            printf '%s\n' "$cmux_ssh_auth_reaper_owner_record" \
              > "$cmux_ssh_auth_reaper_lock/owner.new" 2>/dev/null || ! \
            printf '%s\n' "$cmux_ssh_auth_reaper_owner_record" \
              > "$cmux_ssh_auth_reaper_slot/owner.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_reaper_lock/owner.new" \
              "$cmux_ssh_auth_reaper_lock/owner" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_reaper_slot/owner.new" \
              "$cmux_ssh_auth_reaper_slot/owner" 2>/dev/null || ! \
            cmux_ssh_auth_reaper_owner_matches_generation \
              "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" || ! \
            cmux_ssh_auth_reaper_owner_matches_generation \
              "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation"; then
            cmux_ssh_auth_kill_worker_if_identity_matches \
              "$cmux_ssh_auth_reaper_pid" "$cmux_ssh_auth_reaper_identity" || true
            wait "$cmux_ssh_auth_reaper_pid" 2>/dev/null || true
            cmux_ssh_auth_release_reaper_lock_if_current \
              "$cmux_ssh_auth_reaper_lock" "$cmux_ssh_auth_reaper_generation" 0
            cmux_ssh_auth_release_reaper_lock_if_current \
              "$cmux_ssh_auth_reaper_slot" "$cmux_ssh_auth_reaper_generation" 0
            return 0
          fi
          /bin/rm -f -- "$cmux_ssh_auth_reaper_lock/publisher" \
            "$cmux_ssh_auth_reaper_lock/publisher.new" 2>/dev/null || true
          /bin/rm -f -- "$cmux_ssh_auth_reaper_slot/publisher" \
            "$cmux_ssh_auth_reaper_slot/publisher.new" 2>/dev/null || true
          CMUX_SSH_AUTH_REAPER_LAUNCHED=1
          return 0
        }

        cmux_ssh_auth_recovery_configure_paths() {
          cmux_ssh_auth_recovery_user_id=$(/usr/bin/id -u 2>/dev/null) || return 1
          case "$cmux_ssh_auth_recovery_user_id" in
            ''|*[!0-9]*) return 1 ;;
          esac
          if [ -n "${TMPDIR:-}" ]; then
            cmux_ssh_auth_recovery_base="$TMPDIR"
          else
            cmux_ssh_auth_recovery_base=/tmp
          fi
          cmux_ssh_auth_recovery_root="$cmux_ssh_auth_recovery_base/cmux-ssh-auth-recovery.$cmux_ssh_auth_recovery_user_id"
        }

        cmux_ssh_auth_recovery_prepare() {
          cmux_ssh_auth_recovery_configure_paths || return 1
          if [ -L "$cmux_ssh_auth_recovery_root" ]; then return 1; fi
          if [ ! -d "$cmux_ssh_auth_recovery_root" ]; then
            (umask 077; /bin/mkdir "$cmux_ssh_auth_recovery_root") 2>/dev/null || \
              [ -d "$cmux_ssh_auth_recovery_root" ] || return 1
          fi
          if [ -L "$cmux_ssh_auth_recovery_root" ]; then return 1; fi
          cmux_ssh_auth_recovery_expected_root_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_recovery_observed_root_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_recovery_root" 2>/dev/null || true)
          [ "$cmux_ssh_auth_recovery_observed_root_identity" = \
            "$cmux_ssh_auth_recovery_expected_root_identity" ]
        }

        cmux_ssh_auth_recovery_group_path_is_valid() {
          cmux_ssh_auth_recovery_candidate="$1"
          case "$cmux_ssh_auth_recovery_candidate" in
            "$cmux_ssh_auth_recovery_base"/cmux-ssh-auth-group.*)
              cmux_ssh_auth_recovery_suffix=${cmux_ssh_auth_recovery_candidate##*/cmux-ssh-auth-group.}
              case "$cmux_ssh_auth_recovery_suffix" in
                ''|*[!A-Za-z0-9._-]*) return 1 ;;
              esac
              ;;
            *) return 1 ;;
          esac
          return 0
        }

        cmux_ssh_auth_recovery_lock() {
          cmux_ssh_auth_recovery_prepare || return 1
          exec 9>> "$cmux_ssh_auth_recovery_root/lock" || return 1
          # Perl's flock uses the macOS flock(2) interface available across our
          # deployment range. The child aliases fd 9, so the lock stays on the
          # shared open-file description until the parent closes that fd.
          if ! /usr/bin/perl -MFcntl=:flock -e '
            open(my $lock, ">&=9") or exit 1;
            local $SIG{ALRM} = sub { exit 1 };
            alarm 1;
            flock($lock, LOCK_EX) or exit 1;
            alarm 0;
          '; then
            exec 9>&-
            return 1
          fi
        }

        cmux_ssh_auth_recovery_unlock() {
          exec 9>&-
        }

        cmux_ssh_auth_release_reaper_lock_if_current() {
          CMUX_SSH_AUTH_REAPER_RELEASED=0
          cmux_ssh_auth_release_lock="$1"
          cmux_ssh_auth_release_generation="$2"
          cmux_ssh_auth_release_requires_owner="$3"
          cmux_ssh_auth_recovery_lock || return 1
          if ! cmux_ssh_auth_reaper_generation_is_current \
            "$cmux_ssh_auth_release_lock" \
            "$cmux_ssh_auth_release_generation"; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          if [ "$cmux_ssh_auth_release_requires_owner" = 1 ] && ! \
            cmux_ssh_auth_reaper_owner_matches_generation \
              "$cmux_ssh_auth_release_lock" \
              "$cmux_ssh_auth_release_generation"; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          /bin/rm -f -- "$cmux_ssh_auth_release_lock/owner" \
            "$cmux_ssh_auth_release_lock/owner.new" \
            "$cmux_ssh_auth_release_lock/publisher" \
            "$cmux_ssh_auth_release_lock/publisher.new" \
            "$cmux_ssh_auth_release_lock/generation" \
            "$cmux_ssh_auth_release_lock/generation.new" 2>/dev/null || true
          if /bin/rmdir "$cmux_ssh_auth_release_lock" 2>/dev/null; then
            CMUX_SSH_AUTH_REAPER_RELEASED=1
          fi
          cmux_ssh_auth_recovery_unlock
          [ "$CMUX_SSH_AUTH_REAPER_RELEASED" = 1 ]
        }

        cmux_ssh_auth_reclaim_stale_cleanup_lock() {
          cmux_ssh_auth_stale_cleanup_lock="$1"
          if [ -L "$cmux_ssh_auth_stale_cleanup_lock" ]; then return 1; fi
          if [ ! -d "$cmux_ssh_auth_stale_cleanup_lock" ]; then return 0; fi
          cmux_ssh_auth_stale_cleanup_expected="$(/usr/bin/id -u):700"
          cmux_ssh_auth_stale_cleanup_observed=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_stale_cleanup_lock" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_stale_cleanup_observed" != \
            "$cmux_ssh_auth_stale_cleanup_expected" ]; then return 1; fi
          if cmux_ssh_auth_recorded_process_is_live \
            "$cmux_ssh_auth_stale_cleanup_lock/owner" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_stale_cleanup_lock/owner.new"; then
            return 1
          fi
          /bin/rm -f -- "$cmux_ssh_auth_stale_cleanup_lock/owner" \
            "$cmux_ssh_auth_stale_cleanup_lock/owner.new" 2>/dev/null || true
          /bin/rmdir "$cmux_ssh_auth_stale_cleanup_lock" 2>/dev/null
        }

        cmux_ssh_auth_cleanup_claim_abort_locked() {
          /bin/rm -f -- "$cmux_ssh_auth_cleanup_owner_publish_file" \
            "$cmux_ssh_auth_cleanup_owner_file" \
            "$cmux_ssh_auth_cleanup_lock_owner_publish_file" \
            "$cmux_ssh_auth_cleanup_lock_owner_file" 2>/dev/null || true
          /bin/rmdir "$cmux_ssh_auth_cleanup_lock" 2>/dev/null || true
          cmux_ssh_auth_recovery_unlock
          CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD=
        }

        cmux_ssh_auth_cleanup_claim() {
          CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD=
          cmux_ssh_auth_recovery_lock || return 1
          if cmux_ssh_auth_recorded_process_is_live \
            "$cmux_ssh_auth_cleanup_owner_file" || \
            cmux_ssh_auth_recorded_process_is_live \
              "$cmux_ssh_auth_cleanup_owner_publish_file"; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          /bin/rm -f -- "$cmux_ssh_auth_cleanup_owner_file" \
            "$cmux_ssh_auth_cleanup_owner_publish_file" 2>/dev/null || true
          if ! (umask 077; /bin/mkdir "$cmux_ssh_auth_cleanup_lock") 2>/dev/null; then
            cmux_ssh_auth_reclaim_stale_cleanup_lock \
              "$cmux_ssh_auth_cleanup_lock" || {
                cmux_ssh_auth_recovery_unlock
                return 1
              }
            (umask 077; /bin/mkdir "$cmux_ssh_auth_cleanup_lock") 2>/dev/null || {
              cmux_ssh_auth_recovery_unlock
              return 1
            }
          fi
          # Publish the actual function-subshell worker. POSIX shells retain
          # the parent shell's `$$`, while this direct child reports it as PPID.
          if ! cmux_ssh_auth_publish_current_worker \
            "$cmux_ssh_auth_cleanup_owner_file"; then
            cmux_ssh_auth_cleanup_claim_abort_locked
            return 1
          fi
          cmux_ssh_auth_cleanup_claim_record=$(/bin/cat -- \
            "$cmux_ssh_auth_cleanup_owner_file" 2>/dev/null || true)
          if [ -z "$cmux_ssh_auth_cleanup_claim_record" ] || ! \
            printf '%s\n' "$cmux_ssh_auth_cleanup_claim_record" \
              > "$cmux_ssh_auth_cleanup_lock_owner_publish_file" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_cleanup_lock_owner_publish_file" \
              "$cmux_ssh_auth_cleanup_lock_owner_file" 2>/dev/null; then
            cmux_ssh_auth_cleanup_claim_abort_locked
            return 1
          fi
          CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD="$cmux_ssh_auth_cleanup_claim_record"
          cmux_ssh_auth_recovery_unlock
          cmux_ssh_auth_cleanup_claim_is_current
        }

        cmux_ssh_auth_cleanup_claim_is_current() {
          if [ -z "${CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD:-}" ]; then return 1; fi
          cmux_ssh_auth_cleanup_observed_lock=$(/bin/cat -- \
            "$cmux_ssh_auth_cleanup_lock_owner_file" 2>/dev/null || true)
          cmux_ssh_auth_cleanup_observed_owner=$(/bin/cat -- \
            "$cmux_ssh_auth_cleanup_owner_file" 2>/dev/null || true)
          [ "$cmux_ssh_auth_cleanup_observed_lock" = \
            "$CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD" ] && \
            [ "$cmux_ssh_auth_cleanup_observed_owner" = \
              "$CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD" ]
        }

        cmux_ssh_auth_cleanup_claim_release() {
          if [ -z "${CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD:-}" ]; then return 0; fi
          cmux_ssh_auth_cleanup_observed_lock=$(/bin/cat -- \
            "$cmux_ssh_auth_cleanup_lock_owner_file" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_cleanup_observed_lock" = \
            "$CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD" ]; then
            cmux_ssh_auth_cleanup_observed_owner=$(/bin/cat -- \
              "$cmux_ssh_auth_cleanup_owner_file" 2>/dev/null || true)
            if [ "$cmux_ssh_auth_cleanup_observed_owner" = \
              "$CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD" ]; then
              /bin/rm -f -- "$cmux_ssh_auth_cleanup_owner_file" \
                "$cmux_ssh_auth_cleanup_owner_publish_file" 2>/dev/null || true
            fi
            /bin/rm -f -- "$cmux_ssh_auth_cleanup_lock_owner_file" \
              "$cmux_ssh_auth_cleanup_lock_owner_publish_file" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_cleanup_lock" 2>/dev/null || true
          fi
          CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD=
        }

        cmux_ssh_auth_recovery_read_index() {
          cmux_ssh_auth_recovery_index=$(/bin/cat -- "$1" 2>/dev/null || true)
          case "$cmux_ssh_auth_recovery_index" in
            ''|*[!0-9]*) printf '0\n' ;;
            *)
              if [ "${#cmux_ssh_auth_recovery_index}" -gt 12 ]; then
                printf '0\n'
              else
                printf '%s\n' "$cmux_ssh_auth_recovery_index"
              fi
              ;;
          esac
        }

        cmux_ssh_auth_recovery_write_index_locked() {
          cmux_ssh_auth_recovery_index_file="$1"
          cmux_ssh_auth_recovery_index_value="$2"
          printf '%s\n' "$cmux_ssh_auth_recovery_index_value" \
            > "$cmux_ssh_auth_recovery_index_file.new" 2>/dev/null && \
            /bin/mv -f -- "$cmux_ssh_auth_recovery_index_file.new" \
              "$cmux_ssh_auth_recovery_index_file" 2>/dev/null
        }

        cmux_ssh_auth_recovery_append_locked() {
          cmux_ssh_auth_recovery_append_group="$1"
          cmux_ssh_auth_recovery_group_path_is_valid \
            "$cmux_ssh_auth_recovery_append_group" || return 1
          cmux_ssh_auth_recovery_read_index_value=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/read.index")
          cmux_ssh_auth_recovery_write_index=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/write.index")
          if [ "$cmux_ssh_auth_recovery_write_index" -lt \
            "$cmux_ssh_auth_recovery_read_index_value" ]; then return 1; fi
          cmux_ssh_auth_recovery_segment_span=$((
            cmux_ssh_auth_recovery_write_index - cmux_ssh_auth_recovery_read_index_value
          ))
          # Eight segments of eight records put a fixed 64-group limit on
          # pending recovery work. Check only that bounded window for duplicates.
          if [ "$cmux_ssh_auth_recovery_segment_span" -ge 8 ]; then
            return \#(Self.recoveryQueueCapacityStatus)
          fi
          cmux_ssh_auth_recovery_check_index="$cmux_ssh_auth_recovery_read_index_value"
          while [ "$cmux_ssh_auth_recovery_check_index" -le \
            "$cmux_ssh_auth_recovery_write_index" ]; do
            cmux_ssh_auth_recovery_check_segment="$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_check_index"
            if [ -L "$cmux_ssh_auth_recovery_check_segment" ]; then return 1; fi
            if [ "$cmux_ssh_auth_recovery_check_segment" != \
                "${CMUX_SSH_AUTH_RECOVERY_SEGMENT:-}" ] && \
              [ -f "$cmux_ssh_auth_recovery_check_segment" ]; then
              if /usr/bin/grep -Fqx -- "$cmux_ssh_auth_recovery_append_group" \
                "$cmux_ssh_auth_recovery_check_segment" 2>/dev/null; then
                return 0
              else
                cmux_ssh_auth_recovery_duplicate_status=$?
                if [ "$cmux_ssh_auth_recovery_duplicate_status" -ne 1 ]; then return 1; fi
              fi
            fi
            cmux_ssh_auth_recovery_check_index=$((cmux_ssh_auth_recovery_check_index + 1))
          done
          cmux_ssh_auth_recovery_write_segment="$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_write_index"
          if [ -L "$cmux_ssh_auth_recovery_write_segment" ]; then return 1; fi
          cmux_ssh_auth_recovery_segment_count=0
          if [ -f "$cmux_ssh_auth_recovery_write_segment" ]; then
            cmux_ssh_auth_recovery_segment_count=$(/usr/bin/awk '
              NR == 8 { print 8; cmux_printed = 1; exit }
              END { if (!cmux_printed) print NR + 0 }
            ' "$cmux_ssh_auth_recovery_write_segment" 2>/dev/null || printf '64\n')
          fi
          case "$cmux_ssh_auth_recovery_segment_count" in
            ''|*[!0-9]*) return 1 ;;
          esac
          if [ "$cmux_ssh_auth_recovery_segment_count" -ge 8 ]; then
            if [ "$cmux_ssh_auth_recovery_segment_span" -ge 7 ]; then
              return \#(Self.recoveryQueueCapacityStatus)
            fi
            cmux_ssh_auth_recovery_write_index=$((cmux_ssh_auth_recovery_write_index + 1))
            cmux_ssh_auth_recovery_write_segment="$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_write_index"
            if [ -L "$cmux_ssh_auth_recovery_write_segment" ]; then return 1; fi
          fi
          cmux_ssh_auth_recovery_write_index_locked \
            "$cmux_ssh_auth_recovery_root/write.index" \
            "$cmux_ssh_auth_recovery_write_index" || return 1
          printf '%s\n' "$cmux_ssh_auth_recovery_append_group" \
            >> "$cmux_ssh_auth_recovery_write_segment" 2>/dev/null
        }

        cmux_ssh_auth_recovery_enqueue() {
          cmux_ssh_auth_recovery_prepare || return 1
          cmux_ssh_auth_recovery_group_path_is_valid "$1" || return 1
          cmux_ssh_auth_recovery_lock || return 1
          cmux_ssh_auth_recovery_append_locked "$1"
          cmux_ssh_auth_recovery_enqueue_status=$?
          cmux_ssh_auth_recovery_unlock
          return "$cmux_ssh_auth_recovery_enqueue_status"
        }

        cmux_ssh_auth_create_group_dir() {
          cmux_ssh_auth_recovery_prepare || return 1
          cmux_ssh_auth_create_uuid=$(/usr/bin/uuidgen 2>/dev/null | \
            /usr/bin/tr '[:upper:]' '[:lower:]') || return 1
          case "$cmux_ssh_auth_create_uuid" in
            ''|*[!a-z0-9-]*) return 1 ;;
          esac
          cmux_ssh_auth_create_dir="$cmux_ssh_auth_recovery_base/cmux-ssh-auth-group.$cmux_ssh_auth_create_uuid"
          cmux_ssh_auth_recovery_group_path_is_valid "$cmux_ssh_auth_create_dir" || return 1
          # A recovery worker can hold the shared lock across its bounded queue
          # transaction. Retry the event-driven one-second flock wait without a
          # polling sleep so transient cleanup cannot abort authentication.
          cmux_ssh_auth_create_lock_attempt=0
          while ! cmux_ssh_auth_recovery_lock; do
            cmux_ssh_auth_create_lock_attempt=$((cmux_ssh_auth_create_lock_attempt + 1))
            if [ "$cmux_ssh_auth_create_lock_attempt" -ge 3 ]; then return 1; fi
          done
          cmux_ssh_auth_recovery_append_locked "$cmux_ssh_auth_create_dir"
          cmux_ssh_auth_create_append_status=$?
          if [ "$cmux_ssh_auth_create_append_status" -ne 0 ]; then
            cmux_ssh_auth_recovery_unlock
            return "$cmux_ssh_auth_create_append_status"
          fi
          if ! (umask 077; /bin/mkdir "$cmux_ssh_auth_create_dir") 2>/dev/null; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_create_now=$(/bin/date +%s 2>/dev/null || true)
          case "$cmux_ssh_auth_create_now" in
            ''|*[!0-9]*)
              /bin/rmdir "$cmux_ssh_auth_create_dir" 2>/dev/null || true
              cmux_ssh_auth_recovery_unlock
              return 1
              ;;
          esac
          if ! printf '%s\n' "$cmux_ssh_auth_create_now" \
            > "$cmux_ssh_auth_create_dir/created.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_create_dir/created.new" \
              "$cmux_ssh_auth_create_dir/created" 2>/dev/null; then
            /bin/rm -f -- "$cmux_ssh_auth_create_dir/created.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_create_dir" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_unlock
          printf '%s\n' "$cmux_ssh_auth_create_dir"
        }

        cmux_ssh_auth_resume_pending_handoff() (
          cmux_ssh_auth_pending_group_dir="$1"
          cmux_ssh_auth_recovery_configure_paths || exit 1
          cmux_ssh_auth_recovery_group_path_is_valid \
            "$cmux_ssh_auth_pending_group_dir" || exit 1
          if [ ! -d "$cmux_ssh_auth_pending_group_dir" ] || \
            [ -L "$cmux_ssh_auth_pending_group_dir" ] || \
            [ ! -f "$cmux_ssh_auth_pending_group_dir/handoff-pending" ] || \
            [ -L "$cmux_ssh_auth_pending_group_dir/handoff-pending" ] || \
            [ ! -f "$cmux_ssh_auth_pending_group_dir/unpublished.root" ] || \
            [ -L "$cmux_ssh_auth_pending_group_dir/unpublished.root" ]; then exit 1; fi
          cmux_ssh_auth_pending_expected_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_pending_observed_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_pending_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_pending_observed_identity" != \
            "$cmux_ssh_auth_pending_expected_identity" ]; then exit 1; fi
          if cmux_ssh_auth_group_publisher_is_live \
            "$cmux_ssh_auth_pending_group_dir"; then exit 1; fi
          IFS=' ' read -r cmux_ssh_auth_pending_root_pid \
            cmux_ssh_auth_pending_root_parent cmux_ssh_auth_pending_root_group \
            cmux_ssh_auth_pending_root_started cmux_ssh_auth_pending_root_extra \
            < "$cmux_ssh_auth_pending_group_dir/unpublished.root" || exit 1
          case "$cmux_ssh_auth_pending_root_pid" in ''|0|*[!0-9]*) exit 1 ;; esac
          case "$cmux_ssh_auth_pending_root_parent" in ''|*[!0-9]*) exit 1 ;; esac
          case "$cmux_ssh_auth_pending_root_group" in ''|0|*[!0-9]*) exit 1 ;; esac
          case "$cmux_ssh_auth_pending_root_started" in
            ''|*[!A-Za-z0-9_:]*) exit 1 ;;
          esac
          if [ -n "$cmux_ssh_auth_pending_root_extra" ]; then exit 1; fi
          cmux_ssh_auth_force_unpublished_process_tree \
            "$cmux_ssh_auth_pending_root_pid" \
            "$cmux_ssh_auth_pending_root_parent" \
            "$cmux_ssh_auth_pending_root_group" \
            "$cmux_ssh_auth_pending_root_started" || exit 1
          CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_pending_group_dir"
          export CMUX_SSH_AUTH_GROUP_DIR
          if [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
            cmux_ssh_terminate_owned_auth_group
            if [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then exit 1; fi
          fi
          \#(processGroupStateRemovalShellCommand())
          /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || exit 1
        )

        cmux_ssh_auth_resume_unpublished_rollback() (
          cmux_ssh_auth_rollback_group_dir="$1"
          cmux_ssh_auth_recovery_prepare || exit 1
          cmux_ssh_auth_recovery_group_path_is_valid \
            "$cmux_ssh_auth_rollback_group_dir" || exit 1
          if [ ! -d "$cmux_ssh_auth_rollback_group_dir" ] || \
            [ -L "$cmux_ssh_auth_rollback_group_dir" ] || \
            [ ! -f "$cmux_ssh_auth_rollback_group_dir/rollback-only" ] || \
            [ -L "$cmux_ssh_auth_rollback_group_dir/rollback-only" ] || \
            [ ! -f "$cmux_ssh_auth_rollback_group_dir/unpublished.root" ] || \
            [ -L "$cmux_ssh_auth_rollback_group_dir/unpublished.root" ] || \
            [ ! -f "$cmux_ssh_auth_rollback_group_dir/owned" ] || \
            [ -L "$cmux_ssh_auth_rollback_group_dir/owned" ]; then exit 1; fi
          cmux_ssh_auth_rollback_expected_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_rollback_observed_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_rollback_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_rollback_observed_identity" != \
            "$cmux_ssh_auth_rollback_expected_identity" ]; then exit 1; fi
          if cmux_ssh_auth_group_publisher_is_live \
            "$cmux_ssh_auth_rollback_group_dir"; then exit 1; fi

          cmux_ssh_auth_process_snapshot="$cmux_ssh_auth_rollback_group_dir/processes"
          cmux_ssh_auth_poststop_snapshot="$cmux_ssh_auth_rollback_group_dir/processes.stopped"
          cmux_ssh_auth_owned_processes="$cmux_ssh_auth_rollback_group_dir/owned"
          cmux_ssh_auth_next_owned_processes="$cmux_ssh_auth_rollback_group_dir/owned.next"
          cmux_ssh_auth_owned_groups="$cmux_ssh_auth_rollback_group_dir/groups"
          cmux_ssh_auth_next_owned_groups="$cmux_ssh_auth_rollback_group_dir/groups.next"
          cmux_ssh_auth_resume_groups="$cmux_ssh_auth_rollback_group_dir/groups.resume"
          cmux_ssh_auth_frozen_processes="$cmux_ssh_auth_rollback_group_dir/frozen"
          cmux_ssh_auth_individual_processes="$cmux_ssh_auth_rollback_group_dir/individuals"
          cmux_ssh_auth_ordered_processes="$cmux_ssh_auth_rollback_group_dir/ordered"
          cmux_ssh_auth_signaled_groups="$cmux_ssh_auth_rollback_group_dir/signaled.groups"
          cmux_ssh_auth_signaled_processes="$cmux_ssh_auth_rollback_group_dir/signaled.pids"
          IFS=' ' read -r cmux_ssh_auth_rollback_root_pid \
            cmux_ssh_auth_rollback_root_parent cmux_ssh_auth_rollback_root_group \
            cmux_ssh_auth_rollback_root_started cmux_ssh_auth_rollback_root_extra \
            < "$cmux_ssh_auth_rollback_group_dir/unpublished.root" || exit 1
          case "$cmux_ssh_auth_rollback_root_pid" in ''|0|*[!0-9]*) exit 1 ;; esac
          case "$cmux_ssh_auth_rollback_root_parent" in ''|*[!0-9]*) exit 1 ;; esac
          case "$cmux_ssh_auth_rollback_root_group" in ''|0|*[!0-9]*) exit 1 ;; esac
          case "$cmux_ssh_auth_rollback_root_started" in
            ''|*[!A-Za-z0-9_:]*) exit 1 ;;
          esac
          if [ -n "$cmux_ssh_auth_rollback_root_extra" ]; then exit 1; fi
          cmux_ssh_auth_owned_group=0
          cmux_ssh_auth_caller_group="$cmux_ssh_auth_rollback_root_group"
          cmux_ssh_auth_rollback_started_millis="$(cmux_ssh_auth_now_millis)" || exit 1
          case "$cmux_ssh_auth_rollback_started_millis" in
            ''|*[!0-9]*) exit 1 ;;
          esac
          # The shared resume helper adds its fixed 500 ms safety margin.
          cmux_ssh_auth_hard_deadline_millis="$cmux_ssh_auth_rollback_started_millis"
          cmux_ssh_auth_resume_signaled_processes || exit 1

          # A rollback-only marker owns the entire unpublished process set, not
          # just any STOP journals. Continue the bounded cleanup from its last
          # atomically published ownership closure before removing recovery.
          cmux_ssh_auth_cleanup_started_millis="$(cmux_ssh_auth_now_millis)" || exit 1
          case "$cmux_ssh_auth_cleanup_started_millis" in
            ''|*[!0-9]*) exit 1 ;;
          esac
          cmux_ssh_auth_deadline_millis=$((cmux_ssh_auth_cleanup_started_millis + 2000))
          cmux_ssh_auth_hard_deadline_millis="$cmux_ssh_auth_deadline_millis"
          cmux_ssh_auth_run_cleanup_transactions || exit 1
          if [ -s "$cmux_ssh_auth_owned_processes" ]; then exit 1; fi

          CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_rollback_group_dir"
          export CMUX_SSH_AUTH_GROUP_DIR
          \#(processGroupStateRemovalShellCommand())
          /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null
        )

        cmux_ssh_auth_recovery_claim_segment() {
          CMUX_SSH_AUTH_RECOVERY_SEGMENT=
          CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX=
          CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD=
          cmux_ssh_auth_recovery_lock || return 1
          cmux_ssh_auth_recovery_read_index_value=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/read.index")
          cmux_ssh_auth_recovery_write_index_value=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/write.index")
          if [ "$cmux_ssh_auth_recovery_read_index_value" -gt \
            "$cmux_ssh_auth_recovery_write_index_value" ]; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_segment="$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_read_index_value"
          if [ "$cmux_ssh_auth_recovery_read_index_value" = \
            "$cmux_ssh_auth_recovery_write_index_value" ]; then
            if [ ! -s "$cmux_ssh_auth_recovery_segment" ]; then
              cmux_ssh_auth_recovery_unlock
              return 1
            fi
            cmux_ssh_auth_recovery_next_write=$((cmux_ssh_auth_recovery_write_index_value + 1))
            if ! cmux_ssh_auth_recovery_write_index_locked \
              "$cmux_ssh_auth_recovery_root/write.index" \
              "$cmux_ssh_auth_recovery_next_write"; then
              cmux_ssh_auth_recovery_unlock
              return 1
            fi
          elif [ ! -s "$cmux_ssh_auth_recovery_segment" ]; then
            /bin/rm -f -- "$cmux_ssh_auth_recovery_segment" \
              "$cmux_ssh_auth_recovery_segment.claim" \
              "$cmux_ssh_auth_recovery_segment.claim.new" \
              "$cmux_ssh_auth_recovery_segment.priority" \
              "$cmux_ssh_auth_recovery_segment.retry" 2>/dev/null || true
            cmux_ssh_auth_recovery_next_read=$((cmux_ssh_auth_recovery_read_index_value + 1))
            cmux_ssh_auth_recovery_write_index_locked \
              "$cmux_ssh_auth_recovery_root/read.index" \
              "$cmux_ssh_auth_recovery_next_read" || true
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          if [ -L "$cmux_ssh_auth_recovery_segment" ]; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_claim="$cmux_ssh_auth_recovery_segment.claim"
          if cmux_ssh_auth_recorded_process_is_live "$cmux_ssh_auth_recovery_claim"; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          /bin/rm -f -- "$cmux_ssh_auth_recovery_claim" \
            "$cmux_ssh_auth_recovery_claim.new" 2>/dev/null || true
          # Publish the actual recovery worker, not `$$`: POSIX shells retain
          # the parent shell's `$$` inside a function subshell. A direct child
          # can identify that worker through PPID without a command-substitution
          # process becoming the recorded owner.
          if ! cmux_ssh_auth_publish_current_worker \
            "$cmux_ssh_auth_recovery_claim"; then
            /bin/rm -f -- "$cmux_ssh_auth_recovery_claim" \
              "$cmux_ssh_auth_recovery_claim.new" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_claim_record=$(/bin/cat -- \
            "$cmux_ssh_auth_recovery_claim" 2>/dev/null || true)
          if [ -z "$cmux_ssh_auth_recovery_claim_record" ]; then
            /bin/rm -f -- "$cmux_ssh_auth_recovery_claim" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          CMUX_SSH_AUTH_RECOVERY_SEGMENT="$cmux_ssh_auth_recovery_segment"
          CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX="$cmux_ssh_auth_recovery_read_index_value"
          CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD="$cmux_ssh_auth_recovery_claim_record"
          cmux_ssh_auth_recovery_unlock
          return 0
        }

        cmux_ssh_auth_recovery_complete_segment() {
          cmux_ssh_auth_recovery_lock || return 1
          cmux_ssh_auth_recovery_current_read=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/read.index")
          cmux_ssh_auth_recovery_observed_claim=$(/bin/cat -- \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_recovery_current_read" != \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX" ] || \
            [ "$cmux_ssh_auth_recovery_observed_claim" != \
              "$CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD" ]; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          # Release the claimed read segment before appending retry records.
          # The append path must be able to advance the write window when all
          # eight queue segments are occupied.
          /bin/rm -f -- "$CMUX_SSH_AUTH_RECOVERY_SEGMENT" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim.new" 2>/dev/null || {
              cmux_ssh_auth_recovery_unlock
              return 1
            }
          for cmux_ssh_auth_recovery_requeue_file in \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"; do
            cmux_ssh_auth_recovery_requeue_count=0
            while IFS= read -r cmux_ssh_auth_recovery_requeue_group; do
              cmux_ssh_auth_recovery_requeue_count=$((cmux_ssh_auth_recovery_requeue_count + 1))
              if [ "$cmux_ssh_auth_recovery_requeue_count" -gt 8 ]; then
                cmux_ssh_auth_recovery_unlock
                return 1
              fi
              cmux_ssh_auth_recovery_append_locked \
                "$cmux_ssh_auth_recovery_requeue_group" || {
                  cmux_ssh_auth_recovery_unlock
                  return 1
                }
            done < "$cmux_ssh_auth_recovery_requeue_file"
          done
          /bin/rm -f -- "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority" \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry" 2>/dev/null || true
          cmux_ssh_auth_recovery_next_read=$((CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX + 1))
          if ! cmux_ssh_auth_recovery_write_index_locked \
            "$cmux_ssh_auth_recovery_root/read.index" \
            "$cmux_ssh_auth_recovery_next_read"; then
            cmux_ssh_auth_recovery_unlock
            return 1
          fi
          cmux_ssh_auth_recovery_unlock
          return 0
        }

        cmux_ssh_auth_recovery_relinquish_segment() {
          if [ -z "${CMUX_SSH_AUTH_RECOVERY_SEGMENT:-}" ] || \
            [ -z "${CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD:-}" ]; then return 0; fi
          cmux_ssh_auth_recovery_observed_claim=$(/bin/cat -- \
            "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim" 2>/dev/null || true)
          # A live owner cannot be replaced by another claimant, so its exact
          # record can be removed safely even when the shared lock is unavailable.
          if [ "$cmux_ssh_auth_recovery_observed_claim" = \
            "$CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD" ]; then
            /bin/rm -f -- "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim" \
              "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.claim.new" 2>/dev/null || true
          fi
          CMUX_SSH_AUTH_RECOVERY_SEGMENT=
          CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX=
          CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD=
        }

        cmux_ssh_auth_recovery_queue_has_work_locked() {
          cmux_ssh_auth_recovery_pending_read=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/read.index")
          cmux_ssh_auth_recovery_pending_write=$(cmux_ssh_auth_recovery_read_index \
            "$cmux_ssh_auth_recovery_root/write.index")
          if [ "$cmux_ssh_auth_recovery_pending_read" -lt \
            "$cmux_ssh_auth_recovery_pending_write" ]; then return 0; fi
          [ "$cmux_ssh_auth_recovery_pending_read" = \
            "$cmux_ssh_auth_recovery_pending_write" ] && \
            [ -s "$cmux_ssh_auth_recovery_root/queue.$cmux_ssh_auth_recovery_pending_read" ]
        }

        cmux_ssh_schedule_delayed_auth_group_recovery() {
          case "${CMUX_SSH_AUTH_RECOVERY_RETENTION_RECHECK_SECONDS:-86400}" in
            1|60|300|3600|86400)
              cmux_ssh_auth_recovery_delay_seconds="${CMUX_SSH_AUTH_RECOVERY_RETENTION_RECHECK_SECONDS:-86400}"
              ;;
            *) cmux_ssh_auth_recovery_delay_seconds=86400 ;;
          esac
          cmux_ssh_auth_recovery_lock || return 0
          cmux_ssh_auth_recovery_delay_lock="$cmux_ssh_auth_recovery_root/delay.lock"
          if [ -L "$cmux_ssh_auth_recovery_delay_lock" ]; then
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          if [ -d "$cmux_ssh_auth_recovery_delay_lock" ]; then
            if cmux_ssh_auth_recorded_process_is_live \
                "$cmux_ssh_auth_recovery_delay_lock/owner" || \
              cmux_ssh_auth_recorded_process_is_live \
                "$cmux_ssh_auth_recovery_delay_lock/publisher"; then
              cmux_ssh_auth_recovery_unlock
              return 0
            fi
            cmux_ssh_auth_reclaim_stale_reaper_lock \
              "$cmux_ssh_auth_recovery_delay_lock" || {
                cmux_ssh_auth_recovery_unlock
                return 0
              }
          fi
          (umask 077; /bin/mkdir "$cmux_ssh_auth_recovery_delay_lock") \
            2>/dev/null || {
              cmux_ssh_auth_recovery_unlock
              return 0
            }
          cmux_ssh_auth_recovery_delay_generation=$(/usr/bin/uuidgen \
            2>/dev/null | /usr/bin/awk '{ gsub(/-/, ""); print }')
          case "$cmux_ssh_auth_recovery_delay_generation" in
            ????????????????????????????????)
              case "$cmux_ssh_auth_recovery_delay_generation" in
                *[!A-Fa-f0-9]*) cmux_ssh_auth_recovery_delay_generation= ;;
              esac
              ;;
            *) cmux_ssh_auth_recovery_delay_generation= ;;
          esac
          if [ -z "$cmux_ssh_auth_recovery_delay_generation" ] || ! \
            printf '%s\n' "$cmux_ssh_auth_recovery_delay_generation" \
              > "$cmux_ssh_auth_recovery_delay_lock/generation.new" 2>/dev/null || ! \
            /bin/mv -f -- \
              "$cmux_ssh_auth_recovery_delay_lock/generation.new" \
              "$cmux_ssh_auth_recovery_delay_lock/generation" 2>/dev/null || ! \
            cmux_ssh_auth_publish_current_worker \
              "$cmux_ssh_auth_recovery_delay_lock/publisher"; then
            /bin/rm -f -- "$cmux_ssh_auth_recovery_delay_lock/generation" \
              "$cmux_ssh_auth_recovery_delay_lock/generation.new" \
              "$cmux_ssh_auth_recovery_delay_lock/publisher" \
              "$cmux_ssh_auth_recovery_delay_lock/publisher.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_recovery_delay_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          (
            exec 9>&-
            trap - EXIT HUP INT TERM
            cmux_ssh_auth_recovery_delay_ready=0
            if cmux_ssh_auth_recovery_lock; then
              if cmux_ssh_auth_reaper_generation_is_current \
                  "$cmux_ssh_auth_recovery_delay_lock" \
                  "$cmux_ssh_auth_recovery_delay_generation" && \
                cmux_ssh_auth_reaper_owner_matches_generation \
                  "$cmux_ssh_auth_recovery_delay_lock" \
                  "$cmux_ssh_auth_recovery_delay_generation"; then
                cmux_ssh_auth_recovery_delay_ready=1
              fi
              cmux_ssh_auth_recovery_unlock
            fi
            if [ "$cmux_ssh_auth_recovery_delay_ready" != 1 ]; then exit 0; fi
            /bin/sleep "$cmux_ssh_auth_recovery_delay_seconds"
            cmux_ssh_auth_recovery_delay_ready=0
            if cmux_ssh_auth_recovery_lock; then
              if cmux_ssh_auth_reaper_generation_is_current \
                  "$cmux_ssh_auth_recovery_delay_lock" \
                  "$cmux_ssh_auth_recovery_delay_generation" && \
                cmux_ssh_auth_reaper_owner_matches_generation \
                  "$cmux_ssh_auth_recovery_delay_lock" \
                  "$cmux_ssh_auth_recovery_delay_generation"; then
                /bin/rm -f -- "$cmux_ssh_auth_recovery_delay_lock/owner" \
                  "$cmux_ssh_auth_recovery_delay_lock/owner.new" \
                  "$cmux_ssh_auth_recovery_delay_lock/publisher" \
                  "$cmux_ssh_auth_recovery_delay_lock/publisher.new" \
                  "$cmux_ssh_auth_recovery_delay_lock/generation" \
                  "$cmux_ssh_auth_recovery_delay_lock/generation.new" \
                  2>/dev/null || true
                if /bin/rmdir "$cmux_ssh_auth_recovery_delay_lock" \
                  2>/dev/null; then
                  cmux_ssh_auth_recovery_delay_ready=1
                fi
              fi
              cmux_ssh_auth_recovery_unlock
            fi
            if [ "$cmux_ssh_auth_recovery_delay_ready" = 1 ]; then
              cmux_ssh_schedule_failed_auth_group_recovery
            fi
          ) </dev/null >/dev/null 2>&1 &
          cmux_ssh_auth_recovery_delay_pid=$!
          cmux_ssh_auth_recovery_delay_identity=$(cmux_ssh_auth_stable_identity \
            "$cmux_ssh_auth_recovery_delay_pid")
          cmux_ssh_auth_recovery_delay_owner="reaper-v1|$cmux_ssh_auth_recovery_delay_generation|$cmux_ssh_auth_recovery_delay_pid|$cmux_ssh_auth_recovery_delay_identity"
          cmux_ssh_auth_recovery_delay_failed=0
          if [ -z "$cmux_ssh_auth_recovery_delay_identity" ] || ! \
            cmux_ssh_auth_reaper_generation_is_current \
              "$cmux_ssh_auth_recovery_delay_lock" \
              "$cmux_ssh_auth_recovery_delay_generation" || ! \
            printf '%s\n' "$cmux_ssh_auth_recovery_delay_owner" \
              > "$cmux_ssh_auth_recovery_delay_lock/owner.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_recovery_delay_lock/owner.new" \
              "$cmux_ssh_auth_recovery_delay_lock/owner" 2>/dev/null || ! \
            cmux_ssh_auth_reaper_owner_matches_generation \
              "$cmux_ssh_auth_recovery_delay_lock" \
              "$cmux_ssh_auth_recovery_delay_generation"; then
            cmux_ssh_auth_recovery_delay_failed=1
          fi
          if [ "$cmux_ssh_auth_recovery_delay_failed" = 1 ]; then
            if [ -n "$cmux_ssh_auth_recovery_delay_identity" ]; then
              cmux_ssh_auth_kill_worker_if_identity_matches \
                "$cmux_ssh_auth_recovery_delay_pid" \
                "$cmux_ssh_auth_recovery_delay_identity" || true
            fi
            /bin/rm -f -- "$cmux_ssh_auth_recovery_delay_lock/owner" \
              "$cmux_ssh_auth_recovery_delay_lock/owner.new" \
              "$cmux_ssh_auth_recovery_delay_lock/publisher" \
              "$cmux_ssh_auth_recovery_delay_lock/publisher.new" \
              "$cmux_ssh_auth_recovery_delay_lock/generation" \
              "$cmux_ssh_auth_recovery_delay_lock/generation.new" \
              2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_recovery_delay_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          /bin/rm -f -- "$cmux_ssh_auth_recovery_delay_lock/publisher" \
            "$cmux_ssh_auth_recovery_delay_lock/publisher.new" 2>/dev/null || true
          cmux_ssh_auth_recovery_unlock
          return 0
        }

        cmux_ssh_schedule_failed_auth_group_recovery() {
          if ! command -v cmux_ssh_resume_failed_auth_group_reapers \
            >/dev/null 2>&1; then return 0; fi
          case "${CMUX_SSH_AUTH_RECOVERY_BACKOFF_SECONDS:-}" in
            1|2|4|8|16|32|60) ;;
            *) CMUX_SSH_AUTH_RECOVERY_BACKOFF_SECONDS=1 ;;
          esac

          # Claim one per-user recovery worker before forking. A live worker
          # coalesces duplicate schedule requests. The durable queue preserves
          # work that remains after each bounded pass.
          cmux_ssh_auth_recovery_lock || return 0
          cmux_ssh_auth_recovery_sweep_lock="$cmux_ssh_auth_recovery_root/sweep.lock"
          if [ -L "$cmux_ssh_auth_recovery_sweep_lock" ]; then
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          if [ -d "$cmux_ssh_auth_recovery_sweep_lock" ]; then
            if cmux_ssh_auth_recorded_process_is_live \
                "$cmux_ssh_auth_recovery_sweep_lock/owner" || \
              cmux_ssh_auth_recorded_process_is_live \
                "$cmux_ssh_auth_recovery_sweep_lock/publisher"; then
              cmux_ssh_auth_recovery_sweep_generation=$(/bin/cat -- \
                "$cmux_ssh_auth_recovery_sweep_lock/generation" 2>/dev/null || true)
              case "$cmux_ssh_auth_recovery_sweep_generation" in
                ????????????????????????????????)
                  case "$cmux_ssh_auth_recovery_sweep_generation" in
                    *[!A-Fa-f0-9]*) ;;
                    *)
                      printf '%s\n' "$cmux_ssh_auth_recovery_sweep_generation" \
                        > "$cmux_ssh_auth_recovery_sweep_lock/pending.new" \
                        2>/dev/null && \
                        /bin/mv -f -- \
                          "$cmux_ssh_auth_recovery_sweep_lock/pending.new" \
                          "$cmux_ssh_auth_recovery_sweep_lock/pending" \
                          2>/dev/null || true
                      ;;
                  esac
                  ;;
              esac
              cmux_ssh_auth_recovery_unlock
              return 0
            fi
            cmux_ssh_auth_reclaim_stale_reaper_lock \
              "$cmux_ssh_auth_recovery_sweep_lock" || {
                cmux_ssh_auth_recovery_unlock
                return 0
              }
          fi
          (umask 077; /bin/mkdir "$cmux_ssh_auth_recovery_sweep_lock") \
            2>/dev/null || {
              cmux_ssh_auth_recovery_unlock
              return 0
            }
          cmux_ssh_auth_recovery_sweep_generation=$(/usr/bin/uuidgen \
            2>/dev/null | /usr/bin/awk '{ gsub(/-/, ""); print }')
          if [ "${#cmux_ssh_auth_recovery_sweep_generation}" -ne 32 ]; then
            /bin/rmdir "$cmux_ssh_auth_recovery_sweep_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          case "$cmux_ssh_auth_recovery_sweep_generation" in
            *[!A-Fa-f0-9]*)
              /bin/rmdir "$cmux_ssh_auth_recovery_sweep_lock" 2>/dev/null || true
              cmux_ssh_auth_recovery_unlock
              return 0
              ;;
          esac
          if ! printf '%s\n' "$cmux_ssh_auth_recovery_sweep_generation" \
              > "$cmux_ssh_auth_recovery_sweep_lock/generation.new" 2>/dev/null || ! \
            /bin/mv -f -- \
              "$cmux_ssh_auth_recovery_sweep_lock/generation.new" \
              "$cmux_ssh_auth_recovery_sweep_lock/generation" 2>/dev/null || ! \
            cmux_ssh_auth_publish_current_worker \
              "$cmux_ssh_auth_recovery_sweep_lock/publisher"; then
            /bin/rm -f -- "$cmux_ssh_auth_recovery_sweep_lock/generation" \
              "$cmux_ssh_auth_recovery_sweep_lock/generation.new" \
              "$cmux_ssh_auth_recovery_sweep_lock/publisher" \
              "$cmux_ssh_auth_recovery_sweep_lock/publisher.new" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_recovery_sweep_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          (
            # Background children inherit the parent flock's open-file
            # description. Close it before waiting for the owner publication.
            exec 9>&-
            trap - EXIT HUP INT TERM
            # The worker must inspect every queued group. Durable publisher and
            # cleanup-owner records protect the active group; the scheduling
            # shell's current-group path must not hide it from later passes.
            unset CMUX_SSH_AUTH_GROUP_DIR
            cmux_ssh_auth_recovery_sweep_ready=0
            if cmux_ssh_auth_recovery_lock; then
              if cmux_ssh_auth_reaper_generation_is_current \
                  "$cmux_ssh_auth_recovery_sweep_lock" \
                  "$cmux_ssh_auth_recovery_sweep_generation" && \
                cmux_ssh_auth_reaper_owner_matches_generation \
                  "$cmux_ssh_auth_recovery_sweep_lock" \
                  "$cmux_ssh_auth_recovery_sweep_generation"; then
                cmux_ssh_auth_recovery_sweep_ready=1
              fi
              cmux_ssh_auth_recovery_unlock
            fi
            if [ "$cmux_ssh_auth_recovery_sweep_ready" != 1 ]; then exit 0; fi
            case "${CMUX_SSH_AUTH_RECOVERY_MAX_PASSES:-8}" in
              1|2|3|4|5|6|7|8)
                cmux_ssh_auth_recovery_sweep_max_passes="${CMUX_SSH_AUTH_RECOVERY_MAX_PASSES:-8}"
                ;;
              *) cmux_ssh_auth_recovery_sweep_max_passes=8 ;;
            esac
            cmux_ssh_auth_recovery_sweep_pass=0
            trap 'cmux_ssh_auth_release_reaper_lock_if_current \
              "$cmux_ssh_auth_recovery_sweep_lock" \
              "$cmux_ssh_auth_recovery_sweep_generation" 1 \
              >/dev/null 2>&1 || true' EXIT
            while :; do
              cmux_ssh_auth_recovery_sweep_pass=$((
                cmux_ssh_auth_recovery_sweep_pass + 1
              ))
              cmux_ssh_resume_failed_auth_group_reapers \
                </dev/null >/dev/null 2>&1
              cmux_ssh_auth_recovery_sweep_reschedule=0
              cmux_ssh_auth_recovery_sweep_schedule_delayed=0
              cmux_ssh_auth_recovery_sweep_released=0
              if cmux_ssh_auth_recovery_lock; then
                if cmux_ssh_auth_reaper_generation_is_current \
                    "$cmux_ssh_auth_recovery_sweep_lock" \
                    "$cmux_ssh_auth_recovery_sweep_generation" && \
                  cmux_ssh_auth_reaper_owner_matches_generation \
                    "$cmux_ssh_auth_recovery_sweep_lock" \
                    "$cmux_ssh_auth_recovery_sweep_generation"; then
                  if cmux_ssh_auth_recovery_queue_has_work_locked; then
                    if [ "$cmux_ssh_auth_recovery_sweep_pass" -ge \
                      "$cmux_ssh_auth_recovery_sweep_max_passes" ]; then
                      # Stop one automatic worker at its bounded pass limit.
                      # The durable queue remains for a later explicit sweep.
                      printf 'recovery-v1|%s|%s\n' \
                        "$cmux_ssh_auth_recovery_sweep_generation" \
                        "$cmux_ssh_auth_recovery_sweep_pass" \
                        > "$cmux_ssh_auth_recovery_root/sweep.failed.new" \
                        2>/dev/null && \
                        /bin/mv -f -- \
                          "$cmux_ssh_auth_recovery_root/sweep.failed.new" \
                          "$cmux_ssh_auth_recovery_root/sweep.failed" \
                          2>/dev/null || true
                      /bin/rm -f -- \
                        "$cmux_ssh_auth_recovery_sweep_lock/owner" \
                        "$cmux_ssh_auth_recovery_sweep_lock/owner.new" \
                        "$cmux_ssh_auth_recovery_sweep_lock/publisher" \
                        "$cmux_ssh_auth_recovery_sweep_lock/publisher.new" \
                        "$cmux_ssh_auth_recovery_sweep_lock/generation" \
                        "$cmux_ssh_auth_recovery_sweep_lock/generation.new" \
                        "$cmux_ssh_auth_recovery_sweep_lock/pending" \
                        "$cmux_ssh_auth_recovery_sweep_lock/pending.new" \
                        2>/dev/null || true
                      if /bin/rmdir "$cmux_ssh_auth_recovery_sweep_lock" \
                        2>/dev/null; then
                        cmux_ssh_auth_recovery_sweep_schedule_delayed=1
                        cmux_ssh_auth_recovery_sweep_released=1
                      fi
                    else
                      cmux_ssh_auth_recovery_sweep_reschedule=1
                      /bin/rm -f -- \
                        "$cmux_ssh_auth_recovery_sweep_lock/pending" \
                        "$cmux_ssh_auth_recovery_sweep_lock/pending.new" \
                        2>/dev/null || true
                    fi
                  else
                    /bin/rm -f -- \
                      "$cmux_ssh_auth_recovery_root/sweep.failed" \
                      "$cmux_ssh_auth_recovery_root/sweep.failed.new" \
                      2>/dev/null || true
                    /bin/rm -f -- "$cmux_ssh_auth_recovery_sweep_lock/owner" \
                      "$cmux_ssh_auth_recovery_sweep_lock/owner.new" \
                      "$cmux_ssh_auth_recovery_sweep_lock/publisher" \
                      "$cmux_ssh_auth_recovery_sweep_lock/publisher.new" \
                      "$cmux_ssh_auth_recovery_sweep_lock/generation" \
                      "$cmux_ssh_auth_recovery_sweep_lock/generation.new" \
                      "$cmux_ssh_auth_recovery_sweep_lock/pending" \
                      "$cmux_ssh_auth_recovery_sweep_lock/pending.new" \
                      2>/dev/null || true
                    if /bin/rmdir "$cmux_ssh_auth_recovery_sweep_lock" \
                      2>/dev/null; then
                      cmux_ssh_auth_recovery_sweep_released=1
                    fi
                  fi
                fi
                cmux_ssh_auth_recovery_unlock
              fi
              if [ "$cmux_ssh_auth_recovery_sweep_reschedule" = 1 ]; then
                cmux_ssh_auth_recovery_backoff="$CMUX_SSH_AUTH_RECOVERY_BACKOFF_SECONDS"
                /bin/sleep "$cmux_ssh_auth_recovery_backoff"
                cmux_ssh_auth_recovery_next_backoff=$((cmux_ssh_auth_recovery_backoff * 2))
                if [ "$cmux_ssh_auth_recovery_next_backoff" -gt 60 ]; then
                  cmux_ssh_auth_recovery_next_backoff=60
                fi
                CMUX_SSH_AUTH_RECOVERY_BACKOFF_SECONDS="$cmux_ssh_auth_recovery_next_backoff"
                continue
              fi
              if [ "$cmux_ssh_auth_recovery_sweep_released" = 1 ]; then
                trap - EXIT HUP INT TERM
              fi
              if [ "$cmux_ssh_auth_recovery_sweep_schedule_delayed" = 1 ]; then
                cmux_ssh_schedule_delayed_auth_group_recovery
              fi
              break
            done
          ) </dev/null >/dev/null 2>&1 &
          cmux_ssh_auth_recovery_sweep_pid=$!
          cmux_ssh_auth_recovery_sweep_identity=$(cmux_ssh_auth_stable_identity \
            "$cmux_ssh_auth_recovery_sweep_pid")
          cmux_ssh_auth_recovery_sweep_owner="reaper-v1|$cmux_ssh_auth_recovery_sweep_generation|$cmux_ssh_auth_recovery_sweep_pid|$cmux_ssh_auth_recovery_sweep_identity"
          if [ -z "$cmux_ssh_auth_recovery_sweep_identity" ] || ! \
            cmux_ssh_auth_reaper_generation_is_current \
              "$cmux_ssh_auth_recovery_sweep_lock" \
              "$cmux_ssh_auth_recovery_sweep_generation" || ! \
            printf '%s\n' "$cmux_ssh_auth_recovery_sweep_owner" \
              > "$cmux_ssh_auth_recovery_sweep_lock/owner.new" 2>/dev/null || ! \
            /bin/mv -f -- "$cmux_ssh_auth_recovery_sweep_lock/owner.new" \
              "$cmux_ssh_auth_recovery_sweep_lock/owner" 2>/dev/null || ! \
            cmux_ssh_auth_reaper_owner_matches_generation \
              "$cmux_ssh_auth_recovery_sweep_lock" \
              "$cmux_ssh_auth_recovery_sweep_generation"; then
            cmux_ssh_auth_kill_worker_if_identity_matches \
              "$cmux_ssh_auth_recovery_sweep_pid" \
              "$cmux_ssh_auth_recovery_sweep_identity" || true
            wait "$cmux_ssh_auth_recovery_sweep_pid" 2>/dev/null || true
            /bin/rm -f -- "$cmux_ssh_auth_recovery_sweep_lock/owner" \
              "$cmux_ssh_auth_recovery_sweep_lock/owner.new" \
              "$cmux_ssh_auth_recovery_sweep_lock/publisher" \
              "$cmux_ssh_auth_recovery_sweep_lock/publisher.new" \
              "$cmux_ssh_auth_recovery_sweep_lock/generation" \
              "$cmux_ssh_auth_recovery_sweep_lock/generation.new" \
              "$cmux_ssh_auth_recovery_sweep_lock/pending" \
              "$cmux_ssh_auth_recovery_sweep_lock/pending.new" \
              2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_recovery_sweep_lock" 2>/dev/null || true
            cmux_ssh_auth_recovery_unlock
            return 0
          fi
          /bin/rm -f -- "$cmux_ssh_auth_recovery_sweep_lock/publisher" \
            "$cmux_ssh_auth_recovery_sweep_lock/publisher.new" 2>/dev/null || true
          cmux_ssh_auth_recovery_unlock
          return 0
        }

        cmux_ssh_resume_failed_auth_group_reapers() (
          cmux_ssh_auth_recovery_claim_segment || return 0
          : > "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority" 2>/dev/null || {
            cmux_ssh_auth_recovery_relinquish_segment
            return 0
          }
          : > "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry" 2>/dev/null || {
            cmux_ssh_auth_recovery_relinquish_segment
            return 0
          }
          cmux_ssh_auth_recovery_count=0
          cmux_ssh_auth_recovery_processed=0
          cmux_ssh_auth_recovery_expected_dir_identity="$(/usr/bin/id -u):700"
          while IFS= read -r cmux_ssh_auth_recovery_group_dir; do
            cmux_ssh_auth_recovery_processed=$((cmux_ssh_auth_recovery_processed + 1))
            if [ "$cmux_ssh_auth_recovery_processed" -gt 8 ]; then break; fi
            if ! cmux_ssh_auth_recovery_group_path_is_valid \
              "$cmux_ssh_auth_recovery_group_dir" || \
              [ ! -d "$cmux_ssh_auth_recovery_group_dir" ] || \
              [ -L "$cmux_ssh_auth_recovery_group_dir" ]; then continue; fi
            cmux_ssh_auth_recovery_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \
              "$cmux_ssh_auth_recovery_group_dir" 2>/dev/null || true)
            if [ "$cmux_ssh_auth_recovery_observed_dir_identity" != \
              "$cmux_ssh_auth_recovery_expected_dir_identity" ]; then continue; fi
            if [ "$cmux_ssh_auth_recovery_group_dir" = \
              "${CMUX_SSH_AUTH_GROUP_DIR:-}" ]; then
              printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              continue
            fi
            if [ -L "$cmux_ssh_auth_recovery_group_dir/handoff-pending" ]; then
              continue
            elif [ -f "$cmux_ssh_auth_recovery_group_dir/handoff-pending" ]; then
              if cmux_ssh_auth_group_publisher_is_live \
                  "$cmux_ssh_auth_recovery_group_dir" || ! \
                cmux_ssh_auth_resume_pending_handoff \
                  "$cmux_ssh_auth_recovery_group_dir"; then
                printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                  >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              fi
              continue
            fi
            if [ -L "$cmux_ssh_auth_recovery_group_dir/rollback-only" ]; then
              continue
            elif [ -f "$cmux_ssh_auth_recovery_group_dir/rollback-only" ]; then
              if cmux_ssh_auth_group_publisher_is_live \
                "$cmux_ssh_auth_recovery_group_dir" || ! \
                cmux_ssh_auth_resume_unpublished_rollback \
                  "$cmux_ssh_auth_recovery_group_dir"; then
                printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                  >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              fi
              continue
            fi
            if [ ! -s "$cmux_ssh_auth_recovery_group_dir/identity" ]; then
              if cmux_ssh_auth_group_creation_retention_expired \
                "$cmux_ssh_auth_recovery_group_dir"; then
                (CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_recovery_group_dir"
                  \#(processGroupStateRemovalShellCommand())
                  /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true)
              else
                printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                  >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              fi
              continue
            fi
            if cmux_ssh_auth_group_cleanup_is_abandoned \
              "$cmux_ssh_auth_recovery_group_dir"; then
              :
            elif cmux_ssh_auth_group_publisher_is_live \
              "$cmux_ssh_auth_recovery_group_dir"; then
              /bin/rm -f -- "$cmux_ssh_auth_recovery_group_dir/orphaned" \
                "$cmux_ssh_auth_recovery_group_dir/orphaned.new" 2>/dev/null || true
              # Preserve durable ownership across hard exits. The scheduler
              # applies bounded exponential delay before the next sweep.
              printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              continue
            fi
            if cmux_ssh_auth_group_anchor_is_live \
              "$cmux_ssh_auth_recovery_group_dir"; then
              /bin/rm -f -- "$cmux_ssh_auth_recovery_group_dir/orphaned" \
                "$cmux_ssh_auth_recovery_group_dir/orphaned.new" 2>/dev/null || true
            elif cmux_ssh_auth_group_orphan_retention_expired \
              "$cmux_ssh_auth_recovery_group_dir"; then
              if ! cmux_ssh_auth_recover_expired_orphan \
                "$cmux_ssh_auth_recovery_group_dir"; then
                printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                  >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              fi
              continue
            else
              # A dead anchor cannot be cleaned by a reaper. Retain its state
              # and let later low-cost sweeps enforce the orphan hold period.
              printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
              continue
            fi
            if [ "$cmux_ssh_auth_recovery_count" -ge 8 ]; then
              printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
                >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.priority"
              continue
            fi
            cmux_ssh_launch_owned_auth_group_reaper "$cmux_ssh_auth_recovery_group_dir"
            if [ "${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}" = 1 ]; then
              cmux_ssh_auth_recovery_count=$((cmux_ssh_auth_recovery_count + 1))
            fi
            printf '%s\n' "$cmux_ssh_auth_recovery_group_dir" \
              >> "$CMUX_SSH_AUTH_RECOVERY_SEGMENT.retry"
          done < "$CMUX_SSH_AUTH_RECOVERY_SEGMENT"
          cmux_ssh_auth_recovery_complete_segment || \
            cmux_ssh_auth_recovery_relinquish_segment
          return 0
        )

        cmux_ssh_terminate_owned_auth_group() (
          cmux_ssh_auth_group_dir="${CMUX_SSH_AUTH_GROUP_DIR:-}"
          if [ -z "$cmux_ssh_auth_group_dir" ]; then exit 0; fi
          cmux_ssh_auth_expected_dir_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' "$cmux_ssh_auth_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_observed_dir_identity" != "$cmux_ssh_auth_expected_dir_identity" ]; then exit 0; fi
          cmux_ssh_auth_group_file="$cmux_ssh_auth_group_dir/identity"
          cmux_ssh_auth_group_cancel_file="$cmux_ssh_auth_group_dir/cancel"
          cmux_ssh_auth_cleanup_owner_file="$cmux_ssh_auth_group_dir/cleanup.owner"
          cmux_ssh_auth_cleanup_owner_publish_file="$cmux_ssh_auth_group_dir/cleanup.owner.new"
          cmux_ssh_auth_cleanup_lock="$cmux_ssh_auth_group_dir/cleanup.lock"
          cmux_ssh_auth_cleanup_lock_owner_file="$cmux_ssh_auth_cleanup_lock/owner"
          cmux_ssh_auth_cleanup_lock_owner_publish_file="$cmux_ssh_auth_cleanup_lock/owner.new"
          cmux_ssh_auth_process_snapshot="$cmux_ssh_auth_group_dir/processes"
          cmux_ssh_auth_poststop_snapshot="$cmux_ssh_auth_group_dir/processes.stopped"
          cmux_ssh_auth_owned_processes="$cmux_ssh_auth_group_dir/owned"
          cmux_ssh_auth_next_owned_processes="$cmux_ssh_auth_group_dir/owned.next"
          cmux_ssh_auth_owned_groups="$cmux_ssh_auth_group_dir/groups"
          cmux_ssh_auth_next_owned_groups="$cmux_ssh_auth_group_dir/groups.next"
          cmux_ssh_auth_resume_groups="$cmux_ssh_auth_group_dir/groups.resume"
          cmux_ssh_auth_frozen_processes="$cmux_ssh_auth_group_dir/frozen"
          cmux_ssh_auth_individual_processes="$cmux_ssh_auth_group_dir/individuals"
          cmux_ssh_auth_ordered_processes="$cmux_ssh_auth_group_dir/ordered"
          cmux_ssh_auth_signaled_groups="$cmux_ssh_auth_group_dir/signaled.groups"
          cmux_ssh_auth_signaled_processes="$cmux_ssh_auth_group_dir/signaled.pids"
          cmux_ssh_auth_remove_cancel=0
          cmux_ssh_auth_cancel_published=0
          cmux_ssh_auth_cleanup_started=0
          cmux_ssh_auth_cleanup_complete=0
          cmux_ssh_auth_preserve_group_state=1
          CMUX_SSH_AUTH_CLEANUP_CLAIM_RECORD=
          cmux_ssh_auth_group_state_cleanup() {
            if [ "$cmux_ssh_auth_cleanup_started" = 1 ] && \
              [ "$cmux_ssh_auth_cleanup_complete" != 1 ]; then
              cmux_ssh_auth_deadline_millis="$cmux_ssh_auth_hard_deadline_millis"
              if cmux_ssh_auth_run_cleanup_transactions >/dev/null 2>&1; then
                cmux_ssh_auth_cleanup_complete=1
              else
                cmux_ssh_auth_preserve_group_state=1
                cmux_ssh_auth_resume_signaled_processes
              fi
            fi
            if [ "$cmux_ssh_auth_cleanup_complete" = 1 ]; then
              cmux_ssh_auth_preserve_group_state=0
            fi
            # An unpublished wrapper removes cancel only after observing it
            # and committing to exit. That acknowledgement makes its remaining
            # empty state safe for this still-current owner to reclaim.
            if [ "$cmux_ssh_auth_preserve_group_state" = 1 ] && \
              [ "$cmux_ssh_auth_cancel_published" = 1 ] && \
              [ ! -s "$cmux_ssh_auth_group_file" ] && \
              [ ! -e "$cmux_ssh_auth_group_cancel_file" ]; then
              cmux_ssh_auth_preserve_group_state=0
            fi
            if [ "$cmux_ssh_auth_preserve_group_state" = 1 ]; then
              cmux_ssh_auth_cleanup_claim_release
              return
            fi
            \#(groupStateFileRemovalShellCommand(includingCancellationMarker: false))
            # Keep the claim through every shared journal deletion. Release it
            # while cancel still prevents no-owner state reclamation.
            cmux_ssh_auth_cleanup_claim_release
            if [ "$cmux_ssh_auth_remove_cancel" = 1 ]; then
              /bin/rm -f -- "$cmux_ssh_auth_group_cancel_file" 2>/dev/null || true
            fi
            /bin/rmdir "$cmux_ssh_auth_group_dir" 2>/dev/null || true
          }
          trap 'cmux_ssh_auth_group_state_cleanup' EXIT
          if [ ! -d "$cmux_ssh_auth_group_dir" ]; then exit 0; fi
          # Own cancellation before publishing it. If this worker dies after
          # creating cancel, recovery can prove the owner is stale and adopt
          # the durable group even while its authentication publisher is live.
          cmux_ssh_auth_cleanup_claim || exit 0
          cmux_ssh_auth_cleanup_claim_is_current || exit 0
          : > "$cmux_ssh_auth_group_cancel_file" 2>/dev/null || exit 0
          cmux_ssh_auth_cancel_published=1

          cmux_ssh_auth_group_attempt=0
          while [ -d "$cmux_ssh_auth_group_dir" ] && [ ! -s "$cmux_ssh_auth_group_file" ] && \
            [ "$cmux_ssh_auth_group_attempt" -lt 200 ]; do
            /bin/sleep 0.01
            cmux_ssh_auth_group_attempt=$((cmux_ssh_auth_group_attempt + 1))
          done
          if [ ! -s "$cmux_ssh_auth_group_file" ]; then exit 0; fi
          cmux_ssh_auth_preserve_group_state=1

          cmux_ssh_auth_group_identity=$(/bin/cat -- "$cmux_ssh_auth_group_file" 2>/dev/null || true)
          cmux_ssh_auth_group_anchor=${cmux_ssh_auth_group_identity%%|*}
          cmux_ssh_auth_group_remainder=${cmux_ssh_auth_group_identity#*|}
          cmux_ssh_auth_owned_group=${cmux_ssh_auth_group_remainder%%|*}
          cmux_ssh_auth_anchor_started=${cmux_ssh_auth_group_remainder#*|}
          case "$cmux_ssh_auth_group_anchor:$cmux_ssh_auth_owned_group:$cmux_ssh_auth_anchor_started" in
            *[!A-Za-z0-9_:]*|:*|*:) exit 0 ;;
          esac

          cmux_ssh_auth_caller_group="${1:-}"
          if [ -z "$cmux_ssh_auth_caller_group" ]; then
            cmux_ssh_auth_caller_group=$(/usr/bin/env LC_ALL=C LANG=C \
              /bin/ps -o pgid= -p "$$" 2>/dev/null | /usr/bin/tr -d '[:space:]')
          fi
          case "$cmux_ssh_auth_caller_group" in ''|*[!0-9]*) exit 0 ;; esac
          if [ "$cmux_ssh_auth_owned_group" = "$cmux_ssh_auth_caller_group" ]; then exit 0; fi

          cmux_ssh_auth_anchor_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_group_anchor")
          cmux_ssh_auth_anchor_remainder=${cmux_ssh_auth_anchor_identity#*|}
          cmux_ssh_auth_observed_group=${cmux_ssh_auth_anchor_remainder%%|*}
          cmux_ssh_auth_observed_started=${cmux_ssh_auth_anchor_remainder#*|}
          if [ "$cmux_ssh_auth_observed_group" != "$cmux_ssh_auth_owned_group" ] || \
            [ "$cmux_ssh_auth_observed_started" != "$cmux_ssh_auth_anchor_started" ]; then
            exit 0
          fi

          cmux_ssh_auth_cleanup_claim_is_current || exit 0
          cmux_ssh_auth_claimed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \
            "$cmux_ssh_auth_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_claimed_dir_identity" != \
            "$cmux_ssh_auth_expected_dir_identity" ]; then exit 0; fi
          cmux_ssh_auth_claimed_group_identity=$(/bin/cat -- \
            "$cmux_ssh_auth_group_file" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_claimed_group_identity" != \
            "$cmux_ssh_auth_group_identity" ]; then exit 0; fi
          cmux_ssh_auth_claimed_anchor_identity=$(cmux_ssh_auth_identity \
            "$cmux_ssh_auth_group_anchor")
          cmux_ssh_auth_claimed_anchor_remainder=${cmux_ssh_auth_claimed_anchor_identity#*|}
          cmux_ssh_auth_claimed_group=${cmux_ssh_auth_claimed_anchor_remainder%%|*}
          cmux_ssh_auth_claimed_started=${cmux_ssh_auth_claimed_anchor_remainder#*|}
          if [ "$cmux_ssh_auth_claimed_group" != "$cmux_ssh_auth_owned_group" ] || \
            [ "$cmux_ssh_auth_claimed_started" != "$cmux_ssh_auth_anchor_started" ]; then
            exit 0
          fi
          cmux_ssh_auth_remove_cancel=1
          cmux_ssh_auth_cleanup_started_millis="$(cmux_ssh_auth_now_millis)" || exit 0
          case "$cmux_ssh_auth_cleanup_started_millis" in ''|*[!0-9]*) exit 0 ;; esac
          cmux_ssh_auth_deadline_millis=$((cmux_ssh_auth_cleanup_started_millis + 500))
          cmux_ssh_auth_hard_deadline_millis=$((cmux_ssh_auth_cleanup_started_millis + 2000))
          # A prior cleanup can die after STOP but before its EXIT trap resumes
          # the journal. Reconcile those exact identities before replacing it.
          cmux_ssh_auth_resume_signaled_processes || exit 0
          # Keep prior exact identities as expansion seeds. A child can leave
          # the anchor group or become reparented between cleanup attempts.
          # Expansion validates each saved PID, group, and start time against
          # the new snapshot and removes stale identities.
          if [ ! -e "$cmux_ssh_auth_owned_processes" ]; then
            : > "$cmux_ssh_auth_owned_processes" || exit 0
          fi
          : > "$cmux_ssh_auth_frozen_processes" || exit 0
          : > "$cmux_ssh_auth_signaled_groups" || exit 0
          : > "$cmux_ssh_auth_signaled_processes" || exit 0
          cmux_ssh_auth_cleanup_started=1
          cmux_ssh_auth_run_cleanup_transactions || exit 0
          cmux_ssh_auth_cleanup_complete=1
        )

        cmux_ssh_auth_force_unpublished_process_tree() (
          cmux_ssh_auth_direct_root_pid="$1"
          cmux_ssh_auth_direct_root_parent="$2"
          cmux_ssh_auth_direct_root_group="$3"
          cmux_ssh_auth_direct_root_started="$4"
          case "$cmux_ssh_auth_direct_root_pid:$cmux_ssh_auth_direct_root_parent:$cmux_ssh_auth_direct_root_group:$cmux_ssh_auth_direct_root_started" in
            *[!A-Za-z0-9_:]*|:*|*:) exit 1 ;;
          esac

          cmux_ssh_auth_direct_started_millis="$(cmux_ssh_auth_now_millis)" || exit 1
          case "$cmux_ssh_auth_direct_started_millis" in ''|*[!0-9]*) exit 1 ;; esac
          cmux_ssh_auth_direct_deadline_millis=$((cmux_ssh_auth_direct_started_millis + 2000))
          if cmux_ssh_auth_direct_root_identity=$(cmux_ssh_auth_identity \
            "$cmux_ssh_auth_direct_root_pid" \
            "$cmux_ssh_auth_direct_deadline_millis"); then
            :
          else
            case "$?" in 124) exit 124 ;; *) exit 1 ;; esac
          fi
          if [ "$cmux_ssh_auth_direct_root_identity" != \
            "$cmux_ssh_auth_direct_root_parent|$cmux_ssh_auth_direct_root_group|$cmux_ssh_auth_direct_root_started" ]; then
            exit 1
          fi

          cmux_ssh_auth_direct_stopped_records=
          cmux_ssh_auth_direct_complete=0
          cmux_ssh_auth_direct_resume_stopped() {
            if [ "$cmux_ssh_auth_direct_complete" = 1 ]; then return; fi
            printf '%s\n' "$cmux_ssh_auth_direct_stopped_records" | \
              while IFS='|' read -r cmux_ssh_auth_direct_resume_pid \
                cmux_ssh_auth_direct_resume_group \
                cmux_ssh_auth_direct_resume_started \
                cmux_ssh_auth_direct_resume_extra; do
                case "$cmux_ssh_auth_direct_resume_pid:$cmux_ssh_auth_direct_resume_group:$cmux_ssh_auth_direct_resume_started" in
                  *[!A-Za-z0-9_:]*|:*|*:) continue ;;
                esac
                if [ -n "$cmux_ssh_auth_direct_resume_extra" ]; then continue; fi
                cmux_ssh_auth_direct_resume_current=$(cmux_ssh_auth_stable_identity \
                  "$cmux_ssh_auth_direct_resume_pid") || continue
                if [ "$cmux_ssh_auth_direct_resume_current" = \
                  "$cmux_ssh_auth_direct_resume_group|$cmux_ssh_auth_direct_resume_started" ]; then
                  kill -CONT "$cmux_ssh_auth_direct_resume_pid" >/dev/null 2>&1 || true
                fi
              done
          }
          trap 'cmux_ssh_auth_direct_resume_stopped' EXIT
          trap 'exit 129' HUP
          trap 'exit 130' INT
          trap 'exit 143' TERM

          cmux_ssh_auth_direct_freeze() {
            cmux_ssh_auth_direct_freeze_pid="$1"
            cmux_ssh_auth_direct_freeze_parent="$2"
            cmux_ssh_auth_direct_freeze_group="$3"
            cmux_ssh_auth_direct_freeze_started="$4"
            cmux_ssh_auth_direct_freeze_expected="$cmux_ssh_auth_direct_freeze_parent|$cmux_ssh_auth_direct_freeze_group|$cmux_ssh_auth_direct_freeze_started"
            cmux_ssh_auth_direct_freeze_current=$(cmux_ssh_auth_identity \
              "$cmux_ssh_auth_direct_freeze_pid" \
              "$cmux_ssh_auth_direct_deadline_millis") || return $?
            if [ "$cmux_ssh_auth_direct_freeze_current" != \
              "$cmux_ssh_auth_direct_freeze_expected" ]; then return 1; fi

            # Record before STOP so every normal or trapped exit can resume the
            # exact stable identity. The durable path remains preferred; this
            # bounded fallback is only for failures before any STOP journal.
            if [ -n "$cmux_ssh_auth_direct_stopped_records" ]; then
              cmux_ssh_auth_direct_stopped_records=$(printf '%s\n%s|%s|%s' \
                "$cmux_ssh_auth_direct_stopped_records" \
                "$cmux_ssh_auth_direct_freeze_pid" \
                "$cmux_ssh_auth_direct_freeze_group" \
                "$cmux_ssh_auth_direct_freeze_started") || return 1
            else
              cmux_ssh_auth_direct_stopped_records="$cmux_ssh_auth_direct_freeze_pid|$cmux_ssh_auth_direct_freeze_group|$cmux_ssh_auth_direct_freeze_started"
            fi
            kill -STOP "$cmux_ssh_auth_direct_freeze_pid" >/dev/null 2>&1 || return 1
            while :; do
              if cmux_ssh_auth_direct_freeze_observed=$(cmux_ssh_auth_stopped_identity \
                "$cmux_ssh_auth_direct_freeze_pid" \
                "$cmux_ssh_auth_direct_deadline_millis"); then
                [ "$cmux_ssh_auth_direct_freeze_observed" = \
                  "$cmux_ssh_auth_direct_freeze_expected" ] || return 1
                return 0
              else
                case "$?" in 124) return 124 ;; esac
              fi
              cmux_ssh_auth_direct_freeze_stable=$(cmux_ssh_auth_stable_identity \
                "$cmux_ssh_auth_direct_freeze_pid" \
                "$cmux_ssh_auth_direct_deadline_millis") || return $?
              if [ "$cmux_ssh_auth_direct_freeze_stable" != \
                "$cmux_ssh_auth_direct_freeze_group|$cmux_ssh_auth_direct_freeze_started" ]; then
                return 1
              fi
              /bin/sleep 0.01
            done
          }

          if cmux_ssh_auth_direct_freeze \
            "$cmux_ssh_auth_direct_root_pid" \
            "$cmux_ssh_auth_direct_root_parent" \
            "$cmux_ssh_auth_direct_root_group" \
            "$cmux_ssh_auth_direct_root_started"; then
            :
          else
            case "$?" in 124) exit 124 ;; *) exit 1 ;; esac
          fi

          # State creation can fail while cleanup still owns a live unpublished
          # tree. Freeze each stable parent before child discovery, then KILL the
          # bounded frozen closure root-first. A frozen parent cannot add a late
          # child between its scan and its final signal.
          cmux_ssh_auth_direct_records="$cmux_ssh_auth_direct_stopped_records"
          cmux_ssh_auth_direct_frontier="$cmux_ssh_auth_direct_root_pid"
          cmux_ssh_auth_direct_count=1
          cmux_ssh_auth_direct_depth=0
          cmux_ssh_auth_direct_capture_status=0
          while [ -n "$cmux_ssh_auth_direct_frontier" ]; do
            if [ "$cmux_ssh_auth_direct_depth" -ge 32 ]; then
              cmux_ssh_auth_direct_capture_status=1
              break
            fi
            if cmux_ssh_auth_direct_now=$(cmux_ssh_auth_now_millis); then
              case "$cmux_ssh_auth_direct_now" in
                ''|*[!0-9]*) cmux_ssh_auth_direct_capture_status=1 ;;
              esac
            else
              cmux_ssh_auth_direct_capture_status=1
            fi
            if [ "$cmux_ssh_auth_direct_capture_status" != 0 ]; then break; fi
            if [ "$cmux_ssh_auth_direct_now" -ge \
              "$cmux_ssh_auth_direct_deadline_millis" ]; then
              cmux_ssh_auth_direct_capture_status=124
              break
            fi
            cmux_ssh_auth_direct_next_frontier=
            for cmux_ssh_auth_direct_parent in $cmux_ssh_auth_direct_frontier; do
              cmux_ssh_auth_direct_pgrep_status=0
              cmux_ssh_auth_direct_children=$(/usr/bin/pgrep -P \
                "$cmux_ssh_auth_direct_parent" 2>/dev/null) || \
                cmux_ssh_auth_direct_pgrep_status=$?
              case "$cmux_ssh_auth_direct_pgrep_status" in
                0|1) ;;
                *)
                  cmux_ssh_auth_direct_capture_status=1
                  break
                  ;;
              esac
              for cmux_ssh_auth_direct_pid in $cmux_ssh_auth_direct_children; do
                case "$cmux_ssh_auth_direct_pid" in ''|0|*[!0-9]*) continue ;; esac
                if [ "$cmux_ssh_auth_direct_count" -ge 128 ]; then
                  cmux_ssh_auth_direct_capture_status=1
                  break
                fi
                if cmux_ssh_auth_direct_identity=$(cmux_ssh_auth_identity \
                  "$cmux_ssh_auth_direct_pid" \
                  "$cmux_ssh_auth_direct_deadline_millis"); then
                  :
                else
                  case "$?" in
                    124) cmux_ssh_auth_direct_capture_status=124; break ;;
                    *) continue ;;
                  esac
                fi
                cmux_ssh_auth_direct_parent_observed=${cmux_ssh_auth_direct_identity%%|*}
                cmux_ssh_auth_direct_remainder=${cmux_ssh_auth_direct_identity#*|}
                cmux_ssh_auth_direct_group=${cmux_ssh_auth_direct_remainder%%|*}
                cmux_ssh_auth_direct_started=${cmux_ssh_auth_direct_remainder#*|}
                case "$cmux_ssh_auth_direct_parent_observed:$cmux_ssh_auth_direct_group:$cmux_ssh_auth_direct_started" in
                  *[!A-Za-z0-9_:]*|:*|*:)
                    cmux_ssh_auth_direct_capture_status=1
                    break
                    ;;
                esac
                if [ "$cmux_ssh_auth_direct_parent_observed" != \
                  "$cmux_ssh_auth_direct_parent" ]; then continue; fi
                if cmux_ssh_auth_direct_freeze \
                  "$cmux_ssh_auth_direct_pid" \
                  "$cmux_ssh_auth_direct_parent_observed" \
                  "$cmux_ssh_auth_direct_group" \
                  "$cmux_ssh_auth_direct_started"; then
                  :
                else
                  case "$?" in
                    124) cmux_ssh_auth_direct_capture_status=124 ;;
                    *) cmux_ssh_auth_direct_capture_status=1 ;;
                  esac
                  break
                fi
                cmux_ssh_auth_direct_records="$cmux_ssh_auth_direct_stopped_records"
                cmux_ssh_auth_direct_next_frontier="$cmux_ssh_auth_direct_next_frontier $cmux_ssh_auth_direct_pid"
                cmux_ssh_auth_direct_count=$((cmux_ssh_auth_direct_count + 1))
              done
              if [ "$cmux_ssh_auth_direct_capture_status" != 0 ]; then break; fi
            done
            if [ "$cmux_ssh_auth_direct_capture_status" != 0 ]; then break; fi
            cmux_ssh_auth_direct_frontier="$cmux_ssh_auth_direct_next_frontier"
            cmux_ssh_auth_direct_depth=$((cmux_ssh_auth_direct_depth + 1))
          done

          # A failed freeze can still have a write-ahead record. Include every
          # such identity in the final kill or EXIT-resume decision.
          cmux_ssh_auth_direct_records="$cmux_ssh_auth_direct_stopped_records"
          # An incomplete scan does not prove ownership of the full tree. Exit
          # before KILL so the EXIT trap resumes every exact stopped identity and
          # leaves the root alive for a later cleanup attempt.
          if [ "$cmux_ssh_auth_direct_capture_status" != 0 ]; then exit "$cmux_ssh_auth_direct_capture_status"; fi
          cmux_ssh_auth_direct_kill_status=0
          printf '%s\n' "$cmux_ssh_auth_direct_records" | (
            cmux_ssh_auth_direct_record_status=0
            while IFS='|' read -r cmux_ssh_auth_direct_pid \
              cmux_ssh_auth_direct_group cmux_ssh_auth_direct_started \
              cmux_ssh_auth_direct_extra; do
              case "$cmux_ssh_auth_direct_pid:$cmux_ssh_auth_direct_group:$cmux_ssh_auth_direct_started" in
                *[!A-Za-z0-9_:]*|:*|*:)
                  cmux_ssh_auth_direct_record_status=1
                  continue
                  ;;
              esac
              if [ -n "$cmux_ssh_auth_direct_extra" ]; then
                cmux_ssh_auth_direct_record_status=1
                continue
              fi
              if cmux_ssh_auth_direct_current=$(cmux_ssh_auth_stable_identity \
                "$cmux_ssh_auth_direct_pid" \
                "$cmux_ssh_auth_direct_deadline_millis"); then
                :
              else
                case "$?" in 124) exit 124 ;; *) continue ;; esac
              fi
              if [ "$cmux_ssh_auth_direct_current" != \
                "$cmux_ssh_auth_direct_group|$cmux_ssh_auth_direct_started" ]; then
                continue
              fi
              if ! kill -KILL "$cmux_ssh_auth_direct_pid" >/dev/null 2>&1; then
                if cmux_ssh_auth_direct_after=$(cmux_ssh_auth_stable_identity \
                  "$cmux_ssh_auth_direct_pid" \
                  "$cmux_ssh_auth_direct_deadline_millis"); then
                  if [ "$cmux_ssh_auth_direct_after" = \
                    "$cmux_ssh_auth_direct_group|$cmux_ssh_auth_direct_started" ]; then
                    cmux_ssh_auth_direct_record_status=1
                  fi
                else
                  case "$?" in 124) exit 124 ;; *) : ;; esac
                fi
              fi
            done
            exit "$cmux_ssh_auth_direct_record_status"
          ) || cmux_ssh_auth_direct_kill_status=$?

          if [ "$cmux_ssh_auth_direct_kill_status" = 0 ]; then
            cmux_ssh_auth_direct_complete=1
          fi

          if [ "$cmux_ssh_auth_direct_capture_status" = 124 ] || \
            [ "$cmux_ssh_auth_direct_kill_status" = 124 ]; then exit 124; fi
          if [ "$cmux_ssh_auth_direct_capture_status" != 0 ] || \
            [ "$cmux_ssh_auth_direct_kill_status" != 0 ]; then exit 1; fi
        )

        cmux_ssh_terminate_unpublished_auth_process_tree() (
          cmux_ssh_auth_tree_root_pid="$1"
          cmux_ssh_auth_tree_root_parent="$2"
          cmux_ssh_auth_tree_root_group="$3"
          cmux_ssh_auth_tree_root_started="$4"
          case "$cmux_ssh_auth_tree_root_pid:$cmux_ssh_auth_tree_root_parent:$cmux_ssh_auth_tree_root_group:$cmux_ssh_auth_tree_root_started" in
            *[!A-Za-z0-9_:]*|:*|*:) exit 1 ;;
          esac

          umask 077
          cmux_ssh_auth_tree_state=
          cmux_ssh_auth_tree_created_state=0
          cmux_ssh_auth_recovery_configure_paths || exit 1
          cmux_ssh_auth_tree_candidate="${CMUX_SSH_AUTH_GROUP_DIR:-}"
          if [ -n "$cmux_ssh_auth_tree_candidate" ] && \
            cmux_ssh_auth_recovery_group_path_is_valid \
              "$cmux_ssh_auth_tree_candidate" && \
            [ -d "$cmux_ssh_auth_tree_candidate" ] && \
            [ ! -L "$cmux_ssh_auth_tree_candidate" ]; then
            cmux_ssh_auth_tree_expected_identity="$(/usr/bin/id -u):700"
            cmux_ssh_auth_tree_observed_identity=$(/usr/bin/stat -f '%u:%Lp' \
              "$cmux_ssh_auth_tree_candidate" 2>/dev/null || true)
            if [ "$cmux_ssh_auth_tree_observed_identity" = \
              "$cmux_ssh_auth_tree_expected_identity" ]; then
              cmux_ssh_auth_tree_state="$cmux_ssh_auth_tree_candidate"
            fi
          fi
          if [ -z "$cmux_ssh_auth_tree_state" ]; then
            cmux_ssh_auth_tree_state=$(cmux_ssh_auth_create_group_dir) || exit 1
            cmux_ssh_auth_tree_created_state=1
          fi
          cmux_ssh_auth_tree_complete=0
          cmux_ssh_auth_tree_cleanup_requires_resume=0
          cmux_ssh_auth_tree_remove_state() {
            CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_tree_state"
            export CMUX_SSH_AUTH_GROUP_DIR
            \#(processGroupStateRemovalShellCommand())
            /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true
          }
          cmux_ssh_auth_tree_remove_rollback_state() {
            # Transfer ownership to any concurrently published identity before
            # deleting the completed rollback journals. If publication did not
            # finish, the validated root tree is already gone.
            /bin/rm -f -- "$cmux_ssh_auth_tree_state/rollback-only" 2>/dev/null || true
            /bin/rm -f -- "$cmux_ssh_auth_tree_state/unpublished.root" \
              "$cmux_ssh_auth_tree_state/processes" \
              "$cmux_ssh_auth_tree_state/processes.stopped" \
              "$cmux_ssh_auth_tree_state/owned" \
              "$cmux_ssh_auth_tree_state/owned.next" \
              "$cmux_ssh_auth_tree_state/groups" \
              "$cmux_ssh_auth_tree_state/groups.next" \
              "$cmux_ssh_auth_tree_state/groups.resume" \
              "$cmux_ssh_auth_tree_state/frozen" \
              "$cmux_ssh_auth_tree_state/individuals" \
              "$cmux_ssh_auth_tree_state/ordered" \
              "$cmux_ssh_auth_tree_state/signaled.groups" \
              "$cmux_ssh_auth_tree_state/signaled.pids" 2>/dev/null || true
          }
          cmux_ssh_auth_tree_cleanup() {
            if [ "$cmux_ssh_auth_tree_complete" != 1 ] && \
              [ "$cmux_ssh_auth_tree_cleanup_requires_resume" = 1 ]; then
              # Resume any write-ahead STOP records, then retain the ownership
              # closure even when the journals were empty. Queue the existing
              # group again so a later worker finishes the durable transaction.
              cmux_ssh_auth_resume_signaled_processes || true
              cmux_ssh_auth_recovery_enqueue \
                "$cmux_ssh_auth_tree_state" >/dev/null 2>&1 || true
              cmux_ssh_schedule_failed_auth_group_recovery
              return
            fi
            if [ "$cmux_ssh_auth_tree_complete" = 1 ] && \
              [ "$cmux_ssh_auth_tree_created_state" != 1 ]; then
              cmux_ssh_auth_tree_remove_rollback_state
            elif [ "$cmux_ssh_auth_tree_complete" = 1 ] || \
              [ "$cmux_ssh_auth_tree_created_state" = 1 ]; then
              cmux_ssh_auth_tree_remove_state
            fi
          }
          trap 'cmux_ssh_auth_tree_cleanup' EXIT
          cmux_ssh_auth_process_snapshot="$cmux_ssh_auth_tree_state/processes"
          cmux_ssh_auth_poststop_snapshot="$cmux_ssh_auth_tree_state/processes.stopped"
          cmux_ssh_auth_owned_processes="$cmux_ssh_auth_tree_state/owned"
          cmux_ssh_auth_next_owned_processes="$cmux_ssh_auth_tree_state/owned.next"
          cmux_ssh_auth_owned_groups="$cmux_ssh_auth_tree_state/groups"
          cmux_ssh_auth_next_owned_groups="$cmux_ssh_auth_tree_state/groups.next"
          cmux_ssh_auth_resume_groups="$cmux_ssh_auth_tree_state/groups.resume"
          cmux_ssh_auth_frozen_processes="$cmux_ssh_auth_tree_state/frozen"
          cmux_ssh_auth_individual_processes="$cmux_ssh_auth_tree_state/individuals"
          cmux_ssh_auth_ordered_processes="$cmux_ssh_auth_tree_state/ordered"
          cmux_ssh_auth_signaled_groups="$cmux_ssh_auth_tree_state/signaled.groups"
          cmux_ssh_auth_signaled_processes="$cmux_ssh_auth_tree_state/signaled.pids"
          cmux_ssh_auth_owned_group=0
          # Treat the root's group as shared. The durable transaction signals
          # each validated member instead of risking the caller's process group.
          cmux_ssh_auth_caller_group="$cmux_ssh_auth_tree_root_group"
          printf '%s %s %s %s\n' "$cmux_ssh_auth_tree_root_pid" \
            "$cmux_ssh_auth_tree_root_parent" "$cmux_ssh_auth_tree_root_group" \
            "$cmux_ssh_auth_tree_root_started" \
            > "$cmux_ssh_auth_tree_state/unpublished.root" || exit 1
          printf '%s %s %s %s R\n' "$cmux_ssh_auth_tree_root_pid" \
            "$cmux_ssh_auth_tree_root_parent" "$cmux_ssh_auth_tree_root_group" \
            "$cmux_ssh_auth_tree_root_started" > "$cmux_ssh_auth_owned_processes" || exit 1
          : > "$cmux_ssh_auth_frozen_processes" || exit 1
          : > "$cmux_ssh_auth_signaled_groups" || exit 1
          : > "$cmux_ssh_auth_signaled_processes" || exit 1
          cmux_ssh_auth_tree_started_millis="$(cmux_ssh_auth_now_millis)" || exit 1
          case "$cmux_ssh_auth_tree_started_millis" in ''|*[!0-9]*) exit 1 ;; esac
          cmux_ssh_auth_deadline_millis=$((cmux_ssh_auth_tree_started_millis + 2000))
          # Capture the validated wrapper and its descendants before publisher
          # setup can complete concurrently with wrapper exit. Later snapshots
          # retain each exact descendant as an independent ownership seed.
          cmux_ssh_auth_take_process_snapshot \
            "$cmux_ssh_auth_process_snapshot" || exit 1
          /usr/bin/awk -v cmux_pid="$cmux_ssh_auth_tree_root_pid" \
            -v cmux_group="$cmux_ssh_auth_tree_root_group" \
            -v cmux_started="$cmux_ssh_auth_tree_root_started" '
              NF >= 5 && $1 == cmux_pid && $3 == cmux_group && $4 !~ /Z/ {
                observed_started = $5
                if (NF >= 9) observed_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                if (observed_started == cmux_started) found = 1
              }
              END { exit(found ? 0 : 1) }
            ' "$cmux_ssh_auth_process_snapshot" || exit 1
          cmux_ssh_auth_expand_owned_processes || exit 1
          cmux_ssh_auth_publish_current_worker \
            "$cmux_ssh_auth_tree_state/publisher" || exit 1
          # Publish the marker last so recovery never observes a partial
          # ownership record without a live initialization owner.
          : > "$cmux_ssh_auth_tree_state/rollback-only" || exit 1
          cmux_ssh_auth_tree_cleanup_requires_resume=1
          cmux_ssh_auth_run_cleanup_transactions || exit 1
          cmux_ssh_auth_tree_complete=1
        )

        cmux_ssh_terminate_auth_process_tree() (
          cmux_ssh_auth_root_pid="$1"
          cmux_ssh_auth_root_parent="$2"
          cmux_ssh_auth_root_identity=
          case "$cmux_ssh_auth_root_pid:$cmux_ssh_auth_root_parent" in
            *[!0-9:]*|:*|*:) ;;
            *)
              cmux_ssh_auth_candidate_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_root_pid")
              cmux_ssh_auth_observed_parent=${cmux_ssh_auth_candidate_identity%%|*}
              cmux_ssh_auth_root_remainder=${cmux_ssh_auth_candidate_identity#*|}
              cmux_ssh_auth_root_group=${cmux_ssh_auth_root_remainder%%|*}
              cmux_ssh_auth_root_started=${cmux_ssh_auth_root_remainder#*|}
              case "$cmux_ssh_auth_root_group:$cmux_ssh_auth_root_started" in
                *[!A-Za-z0-9_:]*|:*|*:) ;;
                *)
                  if [ "$cmux_ssh_auth_observed_parent" = "$cmux_ssh_auth_root_parent" ]; then
                    cmux_ssh_auth_root_identity="$cmux_ssh_auth_candidate_identity"
                  fi
                  ;;
              esac
              ;;
          esac

          if [ -z "$cmux_ssh_auth_root_identity" ]; then exit 0; fi
          cmux_ssh_auth_durable_cleanup_pending=0
          cmux_ssh_auth_select_secure_unpublished_state() {
            cmux_ssh_auth_recovery_configure_paths || return 1
            cmux_ssh_auth_preserve_state="${CMUX_SSH_AUTH_GROUP_DIR:-}"
            if [ -z "$cmux_ssh_auth_preserve_state" ] || \
              ! cmux_ssh_auth_recovery_group_path_is_valid \
                "$cmux_ssh_auth_preserve_state" || \
              [ ! -d "$cmux_ssh_auth_preserve_state" ] || \
              [ -L "$cmux_ssh_auth_preserve_state" ]; then
              cmux_ssh_auth_preserve_state=$(cmux_ssh_auth_create_group_dir) || return 1
              CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_preserve_state"
              export CMUX_SSH_AUTH_GROUP_DIR
            fi
            cmux_ssh_auth_preserve_expected="$(/usr/bin/id -u):700"
            cmux_ssh_auth_preserve_observed=$(/usr/bin/stat -f '%u:%Lp' \
              "$cmux_ssh_auth_preserve_state" 2>/dev/null || true)
            if [ "$cmux_ssh_auth_preserve_observed" != \
              "$cmux_ssh_auth_preserve_expected" ]; then
              cmux_ssh_auth_preserve_state=$(cmux_ssh_auth_create_group_dir) || return 1
              CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_preserve_state"
              export CMUX_SSH_AUTH_GROUP_DIR
              cmux_ssh_auth_preserve_observed=$(/usr/bin/stat -f '%u:%Lp' \
                "$cmux_ssh_auth_preserve_state" 2>/dev/null || true)
            fi
            [ "$cmux_ssh_auth_preserve_observed" = \
              "$cmux_ssh_auth_preserve_expected" ]
          }
          cmux_ssh_auth_preserve_unpublished_root() {
            cmux_ssh_auth_preserve_deadline="${1:-}"
            cmux_ssh_auth_select_secure_unpublished_state || return 1
            if [ -s "$cmux_ssh_auth_preserve_state/identity" ]; then
              cmux_ssh_terminate_owned_auth_group
              return 0
            fi
            # A prior call can finish the ownership journal but fail to enqueue
            # it. Do not replace that validated descendant set with only the
            # root when the handoff is retried.
            if [ -f "$cmux_ssh_auth_preserve_state/rollback-only" ] && \
              [ -s "$cmux_ssh_auth_preserve_state/owned" ]; then
              cmux_ssh_auth_recovery_enqueue \
                "$cmux_ssh_auth_preserve_state" >/dev/null 2>&1 || return 1
              cmux_ssh_schedule_failed_auth_group_recovery
              return 0
            fi
            umask 077
            cmux_ssh_auth_process_snapshot="$cmux_ssh_auth_preserve_state/processes"
            cmux_ssh_auth_owned_processes="$cmux_ssh_auth_preserve_state/owned"
            cmux_ssh_auth_next_owned_processes="$cmux_ssh_auth_preserve_state/owned.next"
            cmux_ssh_auth_owned_group=0
            # The authentication root can share its process group with the
            # caller. Capture from exact process identities, not group scope.
            cmux_ssh_auth_caller_group="$cmux_ssh_auth_root_group"
            printf '%s %s %s %s\n' "$cmux_ssh_auth_root_pid" \
              "$cmux_ssh_auth_observed_parent" "$cmux_ssh_auth_root_group" \
              "$cmux_ssh_auth_root_started" \
              > "$cmux_ssh_auth_preserve_state/unpublished.root" || return 1
            if [ -s "$cmux_ssh_auth_owned_processes" ]; then
              /bin/cp -- "$cmux_ssh_auth_owned_processes" \
                "$cmux_ssh_auth_next_owned_processes" || return 1
              printf '%s %s %s %s R\n' "$cmux_ssh_auth_root_pid" \
                "$cmux_ssh_auth_observed_parent" "$cmux_ssh_auth_root_group" \
                "$cmux_ssh_auth_root_started" \
                >> "$cmux_ssh_auth_next_owned_processes" || return 1
              /bin/mv -f -- "$cmux_ssh_auth_next_owned_processes" \
                "$cmux_ssh_auth_owned_processes" || return 1
            else
              printf '%s %s %s %s R\n' "$cmux_ssh_auth_root_pid" \
                "$cmux_ssh_auth_observed_parent" "$cmux_ssh_auth_root_group" \
                "$cmux_ssh_auth_root_started" \
                > "$cmux_ssh_auth_owned_processes" || return 1
            fi
            case "$cmux_ssh_auth_preserve_deadline" in
              ''|*[!0-9]*)
                cmux_ssh_auth_preserve_started=$(cmux_ssh_auth_now_millis) || return 1
                case "$cmux_ssh_auth_preserve_started" in
                  ''|*[!0-9]*) return 1 ;;
                esac
                cmux_ssh_auth_preserve_deadline=$((
                  cmux_ssh_auth_preserve_started + 2000
                ))
                ;;
            esac
            cmux_ssh_auth_take_process_snapshot_until \
              "$cmux_ssh_auth_process_snapshot" \
              "$cmux_ssh_auth_preserve_deadline" || return 1
            /usr/bin/awk -v cmux_pid="$cmux_ssh_auth_root_pid" \
              -v cmux_group="$cmux_ssh_auth_root_group" \
              -v cmux_started="$cmux_ssh_auth_root_started" '
                NF >= 5 && $1 == cmux_pid && $3 == cmux_group && $4 !~ /Z/ {
                  observed_started = $5
                  if (NF >= 9) observed_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                  if (observed_started == cmux_started) found = 1
                }
                END { exit(found ? 0 : 1) }
              ' "$cmux_ssh_auth_process_snapshot" || return 1
            cmux_ssh_auth_expand_owned_processes || return 1
            /usr/bin/awk -v cmux_pid="$cmux_ssh_auth_root_pid" \
              -v cmux_group="$cmux_ssh_auth_root_group" \
              -v cmux_started="$cmux_ssh_auth_root_started" '
                NF == 5 && $1 == cmux_pid && $3 == cmux_group && \
                  $4 == cmux_started { found = 1 }
                END { exit(found ? 0 : 1) }
              ' "$cmux_ssh_auth_owned_processes" || return 1
            # Publish the marker only after the exact root and its validated
            # descendant closure are durable in the ownership journal.
            : > "$cmux_ssh_auth_preserve_state/rollback-only" || return 1
            cmux_ssh_auth_recovery_enqueue \
              "$cmux_ssh_auth_preserve_state" >/dev/null 2>&1 || return 1
            cmux_ssh_schedule_failed_auth_group_recovery
            return 0
          }
          cmux_ssh_auth_publish_pending_handoff() {
            cmux_ssh_auth_select_secure_unpublished_state || return 1
            if [ -s "$cmux_ssh_auth_preserve_state/identity" ]; then
              cmux_ssh_terminate_owned_auth_group
              return 0
            fi
            umask 077
            printf '%s %s %s %s\n' "$cmux_ssh_auth_root_pid" \
              "$cmux_ssh_auth_observed_parent" "$cmux_ssh_auth_root_group" \
              "$cmux_ssh_auth_root_started" \
              > "$cmux_ssh_auth_preserve_state/unpublished.root.new" || return 1
            /bin/mv -f -- \
              "$cmux_ssh_auth_preserve_state/unpublished.root.new" \
              "$cmux_ssh_auth_preserve_state/unpublished.root" || return 1
            : > "$cmux_ssh_auth_preserve_state/handoff-pending.new" || return 1
            /bin/mv -f -- "$cmux_ssh_auth_preserve_state/handoff-pending.new" \
              "$cmux_ssh_auth_preserve_state/handoff-pending" || return 1
            cmux_ssh_auth_recovery_enqueue \
              "$cmux_ssh_auth_preserve_state" >/dev/null 2>&1 || return 1
            cmux_ssh_schedule_failed_auth_group_recovery
            return 0
          }
          if [ -z "${CMUX_SSH_AUTH_GROUP_DIR:-}" ] || \
            [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
            if cmux_ssh_terminate_unpublished_auth_process_tree \
              "$cmux_ssh_auth_root_pid" "$cmux_ssh_auth_observed_parent" \
              "$cmux_ssh_auth_root_group" "$cmux_ssh_auth_root_started"; then
              # Publication can finish while the root snapshot is frozen. If it
              # did, drain the durable group too; otherwise the validated root
              # transaction already covered every pre-publication descendant.
              if [ -n "${CMUX_SSH_AUTH_GROUP_DIR:-}" ] && \
                [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
                cmux_ssh_terminate_owned_auth_group
              fi
            else
              # Do not kill the root after a partial STOP or snapshot. Keep the
              # durable root attached until recovery can rescan the full tree.
              cmux_ssh_terminate_owned_auth_group
              # The unpublished transaction publishes rollback-only before it
              # can issue STOP. Without that marker, setup failed while the
              # root was still safe for the final stable-identity KILL below.
              if [ -n "${CMUX_SSH_AUTH_GROUP_DIR:-}" ] && \
                [ -f "$CMUX_SSH_AUTH_GROUP_DIR/rollback-only" ]; then
                cmux_ssh_auth_recovery_enqueue \
                  "$CMUX_SSH_AUTH_GROUP_DIR" >/dev/null 2>&1 || true
                cmux_ssh_schedule_failed_auth_group_recovery
                cmux_ssh_auth_durable_cleanup_pending=1
              else
                if cmux_ssh_auth_force_unpublished_process_tree \
                  "$cmux_ssh_auth_root_pid" "$cmux_ssh_auth_observed_parent" \
                  "$cmux_ssh_auth_root_group" "$cmux_ssh_auth_root_started"; then
                  :
                else
                  # The bounded fallback resumed its partial STOP journal. Use
                  # at most two synchronous handoff attempts so TERM and Ctrl-C
                  # can return within a fixed limit.
                  cmux_ssh_auth_handoff_started=$(cmux_ssh_auth_now_millis) || \
                    cmux_ssh_auth_handoff_started=0
                  case "$cmux_ssh_auth_handoff_started" in
                    ''|*[!0-9]*) cmux_ssh_auth_handoff_started=0 ;;
                  esac
                  cmux_ssh_auth_handoff_deadline_millis=$((
                    cmux_ssh_auth_handoff_started + 5000
                  ))
                  cmux_ssh_auth_handoff_attempt=0
                  while [ "$cmux_ssh_auth_handoff_attempt" -lt 2 ]; do
                    cmux_ssh_auth_handoff_attempt=$((
                      cmux_ssh_auth_handoff_attempt + 1
                    ))
                    if cmux_ssh_auth_preserve_unpublished_root \
                        "$cmux_ssh_auth_handoff_deadline_millis"; then
                      cmux_ssh_auth_durable_cleanup_pending=1
                      break
                    fi
                    if cmux_ssh_auth_force_unpublished_process_tree \
                        "$cmux_ssh_auth_root_pid" \
                        "$cmux_ssh_auth_observed_parent" \
                        "$cmux_ssh_auth_root_group" \
                        "$cmux_ssh_auth_root_started"; then
                      break
                    fi
                    cmux_ssh_auth_handoff_now=$(cmux_ssh_auth_now_millis) || break
                    case "$cmux_ssh_auth_handoff_now" in
                      ''|*[!0-9]*) break ;;
                    esac
                    if [ "$cmux_ssh_auth_handoff_now" -ge \
                      "$cmux_ssh_auth_handoff_deadline_millis" ]; then break; fi
                    if [ "$cmux_ssh_auth_handoff_attempt" -lt 2 ]; then
                      /bin/sleep 1
                    fi
                  done
                  # A completed journal is durable proof even if its first queue
                  # append failed. The group cleanup retries that append and
                  # keeps rollback-only state out of the removal path.
                  if [ "$cmux_ssh_auth_durable_cleanup_pending" != 1 ] && \
                    [ -n "${CMUX_SSH_AUTH_GROUP_DIR:-}" ] && \
                    [ -f "$CMUX_SSH_AUTH_GROUP_DIR/rollback-only" ] && \
                    [ -s "$CMUX_SSH_AUTH_GROUP_DIR/owned" ]; then
                    cmux_ssh_auth_recovery_enqueue \
                      "$CMUX_SSH_AUTH_GROUP_DIR" >/dev/null 2>&1 || true
                    cmux_ssh_schedule_failed_auth_group_recovery
                    cmux_ssh_auth_durable_cleanup_pending=1
                  fi
                  # If a complete descendant snapshot is not available, queue
                  # the exact root for the dedicated bounded recovery path.
                  if [ "$cmux_ssh_auth_durable_cleanup_pending" != 1 ] && \
                    cmux_ssh_auth_publish_pending_handoff; then
                    cmux_ssh_auth_durable_cleanup_pending=1
                  fi
                  if [ "$cmux_ssh_auth_durable_cleanup_pending" != 1 ] && \
                    cmux_ssh_auth_current_root_identity=$(cmux_ssh_auth_identity \
                      "$cmux_ssh_auth_root_pid") && \
                    [ "$cmux_ssh_auth_current_root_identity" = \
                      "$cmux_ssh_auth_root_identity" ] && \
                    cmux_ssh_auth_select_secure_unpublished_state; then
                    cmux_ssh_auth_handoff_state="$cmux_ssh_auth_preserve_state"
                    cmux_ssh_auth_handoff_owner="$cmux_ssh_auth_handoff_state/handoff.owner"
                    cmux_ssh_auth_handoff_accepted="$cmux_ssh_auth_handoff_state/handoff.accepted"
                    if cmux_ssh_auth_recorded_process_is_live \
                        "$cmux_ssh_auth_handoff_owner" && \
                      : > "$cmux_ssh_auth_handoff_accepted" && \
                      cmux_ssh_auth_recorded_process_is_live \
                        "$cmux_ssh_auth_handoff_owner"; then
                      cmux_ssh_auth_durable_cleanup_pending=1
                    else
                      /bin/rm -f -- "$cmux_ssh_auth_handoff_owner" \
                        "$cmux_ssh_auth_handoff_owner.new" \
                        "$cmux_ssh_auth_handoff_accepted" \
                        "$cmux_ssh_auth_handoff_state/handoff.failed" 2>/dev/null || true
                      # The detached owner publishes its exact stable identity
                      # before the parent accepts the handoff. It has one fixed
                      # retry budget and publishes the durable pending marker
                      # before it can leave work to the per-user recovery owner.
                      (
                        trap '' HUP INT TERM
                        cmux_ssh_auth_background_state="$cmux_ssh_auth_handoff_state"
                        cmux_ssh_auth_background_owner="$cmux_ssh_auth_background_state/handoff.owner"
                        cmux_ssh_auth_background_accepted="$cmux_ssh_auth_background_state/handoff.accepted"
                        cmux_ssh_auth_publish_current_worker \
                          "$cmux_ssh_auth_background_owner" || exit 1
                        cmux_ssh_auth_background_accept_wait=0
                        while [ ! -f "$cmux_ssh_auth_background_accepted" ] && \
                          [ "$cmux_ssh_auth_background_accept_wait" -lt 100 ]; do
                          /bin/sleep 0.01
                          cmux_ssh_auth_background_accept_wait=$((
                            cmux_ssh_auth_background_accept_wait + 1
                          ))
                        done
                        if [ ! -f "$cmux_ssh_auth_background_accepted" ]; then exit 1; fi
                        trap '/bin/rm -f -- \
                          "$cmux_ssh_auth_background_owner" \
                          "$cmux_ssh_auth_background_owner.new" \
                          "$cmux_ssh_auth_background_accepted" 2>/dev/null || true' EXIT
                        cmux_ssh_auth_background_retry_delay=1
                        cmux_ssh_auth_background_attempt=0
                        while [ "$cmux_ssh_auth_background_attempt" -lt 8 ]; do
                          cmux_ssh_auth_background_attempt=$((
                            cmux_ssh_auth_background_attempt + 1
                          ))
                          if cmux_ssh_auth_preserve_unpublished_root; then exit 0; fi
                          if [ -n "${CMUX_SSH_AUTH_GROUP_DIR:-}" ] && \
                            [ -f "$CMUX_SSH_AUTH_GROUP_DIR/rollback-only" ] && \
                            [ -s "$CMUX_SSH_AUTH_GROUP_DIR/owned" ]; then
                            cmux_ssh_auth_recovery_enqueue \
                              "$CMUX_SSH_AUTH_GROUP_DIR" >/dev/null 2>&1 || true
                            cmux_ssh_schedule_failed_auth_group_recovery
                            exit 0
                          fi
                          if cmux_ssh_auth_publish_pending_handoff; then exit 0; fi
                          if cmux_ssh_auth_force_unpublished_process_tree \
                              "$cmux_ssh_auth_root_pid" \
                              "$cmux_ssh_auth_observed_parent" \
                              "$cmux_ssh_auth_root_group" \
                              "$cmux_ssh_auth_root_started"; then
                            /bin/rm -f -- \
                              "$CMUX_SSH_AUTH_GROUP_DIR/handoff-pending" \
                              "$CMUX_SSH_AUTH_GROUP_DIR/handoff-pending.new" \
                              2>/dev/null || true
                            if [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
                              cmux_ssh_terminate_owned_auth_group
                            fi
                            if [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
                              cmux_ssh_auth_recovery_enqueue \
                                "$CMUX_SSH_AUTH_GROUP_DIR" >/dev/null 2>&1 || true
                              cmux_ssh_schedule_failed_auth_group_recovery
                            else
                              \#(processGroupStateRemovalShellCommand())
                              /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true
                            fi
                            exit 0
                          fi
                          if [ "$cmux_ssh_auth_background_attempt" -lt 8 ]; then
                            /bin/sleep "$cmux_ssh_auth_background_retry_delay"
                            case "$cmux_ssh_auth_background_retry_delay" in
                              1|2|4)
                                cmux_ssh_auth_background_retry_delay=$((
                                  cmux_ssh_auth_background_retry_delay * 2
                                ))
                                ;;
                              *) cmux_ssh_auth_background_retry_delay=8 ;;
                            esac
                          fi
                        done
                        printf 'cleanup-incomplete attempts=%s\n' \
                          "$cmux_ssh_auth_background_attempt" \
                          > "$cmux_ssh_auth_background_state/handoff.failed.new" \
                          2>/dev/null && \
                          /bin/mv -f -- \
                            "$cmux_ssh_auth_background_state/handoff.failed.new" \
                            "$cmux_ssh_auth_background_state/handoff.failed" \
                            2>/dev/null || true
                        /usr/bin/logger -t cmux \
                          "SSH authentication handoff stopped after bounded retries" \
                          >/dev/null 2>&1 || true
                        exit 1
                      ) </dev/null >/dev/null 2>&1 &
                      cmux_ssh_auth_background_owner_pid=$!
                      cmux_ssh_auth_background_owner_identity=$(cmux_ssh_auth_stable_identity \
                        "$cmux_ssh_auth_background_owner_pid") || \
                        cmux_ssh_auth_background_owner_identity=
                      cmux_ssh_auth_background_ack_started=$(cmux_ssh_auth_now_millis) || \
                        cmux_ssh_auth_background_ack_started=0
                      case "$cmux_ssh_auth_background_ack_started" in
                        ''|*[!0-9]*) cmux_ssh_auth_background_ack_started=0 ;;
                      esac
                      cmux_ssh_auth_background_ack_deadline=$((
                        cmux_ssh_auth_background_ack_started + 500
                      ))
                      while :; do
                        if cmux_ssh_auth_recorded_process_is_live \
                            "$cmux_ssh_auth_handoff_owner" && \
                          : > "$cmux_ssh_auth_handoff_accepted" && \
                          cmux_ssh_auth_recorded_process_is_live \
                            "$cmux_ssh_auth_handoff_owner"; then
                          cmux_ssh_auth_durable_cleanup_pending=1
                          break
                        fi
                        /bin/kill -0 "$cmux_ssh_auth_background_owner_pid" \
                          >/dev/null 2>&1 || break
                        cmux_ssh_auth_background_ack_now=$(cmux_ssh_auth_now_millis) || break
                        case "$cmux_ssh_auth_background_ack_now" in
                          ''|*[!0-9]*) break ;;
                        esac
                        if [ "$cmux_ssh_auth_background_ack_now" -ge \
                          "$cmux_ssh_auth_background_ack_deadline" ]; then break; fi
                        /bin/sleep 0.01
                      done
                      if [ "$cmux_ssh_auth_durable_cleanup_pending" != 1 ]; then
                        cmux_ssh_auth_kill_worker_if_identity_matches \
                          "$cmux_ssh_auth_background_owner_pid" \
                          "$cmux_ssh_auth_background_owner_identity" || true
                        wait "$cmux_ssh_auth_background_owner_pid" 2>/dev/null || true
                        /bin/rm -f -- "$cmux_ssh_auth_handoff_owner" \
                          "$cmux_ssh_auth_handoff_owner.new" \
                          "$cmux_ssh_auth_handoff_accepted" 2>/dev/null || true
                      fi
                    fi
                  fi
                fi
              fi
            fi
          else
            cmux_ssh_terminate_owned_auth_group
          fi
          if [ "$cmux_ssh_auth_durable_cleanup_pending" != 1 ]; then
            cmux_ssh_auth_current_root_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_root_pid")
            if [ "$cmux_ssh_auth_current_root_identity" = "$cmux_ssh_auth_root_identity" ]; then
              kill -KILL "$cmux_ssh_auth_root_pid" >/dev/null 2>&1 || true
            fi
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
    /// When the caller supplies an owned-group directory, completion hands its
    /// live identity to the enclosing retry wrapper for bounded final cleanup.
    ///
    /// The command must contain only the foreground authentication attempt and
    /// its required preflight, lock, and cleanup work. Callers execute unrelated
    /// local commands after this wrapper returns so their statuses are not
    /// interpreted as SSH authentication failures.
    ///
    /// - Parameter command: Foreground authentication command to execute under zsh.
    /// - Returns: A zsh command suitable for embedding in a startup script.
    public func classifyingTransientFailure(in command: String) -> String {
        let ownedGroupCommand = [
            processIdentityShellFunctions(),
            recordedProcessLivenessShellFunctions(),
            "cmux_ssh_auth_group_dir=\"${CMUX_SSH_AUTH_GROUP_DIR:-}\"",
            "if [ -z \"$cmux_ssh_auth_group_dir\" ]; then exec /usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command)); fi",
            "cmux_ssh_auth_expected_dir_identity=\"$(/usr/bin/id -u):700\"",
            "cmux_ssh_auth_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' \"$cmux_ssh_auth_group_dir\" 2>/dev/null || true)",
            "if [ \"$cmux_ssh_auth_observed_dir_identity\" != \"$cmux_ssh_auth_expected_dir_identity\" ]; then exit 255; fi",
            "cmux_ssh_auth_group_file=\"$cmux_ssh_auth_group_dir/identity\"",
            "cmux_ssh_auth_group_anchor_pid=",
            "cmux_ssh_auth_group_anchor_guard_fd=",
            "cmux_ssh_auth_group_anchor_fifo=\"$cmux_ssh_auth_group_dir/anchor\"",
            "cmux_ssh_auth_group_publish_file=\"$cmux_ssh_auth_group_dir/identity.new\"",
            "cmux_ssh_auth_group_publisher_file=\"$cmux_ssh_auth_group_dir/publisher\"",
            "cmux_ssh_auth_group_publisher_publish_file=\"$cmux_ssh_auth_group_dir/publisher.new\"",
            "cmux_ssh_auth_group_cancel_file=\"$cmux_ssh_auth_group_dir/cancel\"",
            "cmux_ssh_auth_group_published=0",
            "cmux_ssh_auth_group_cleanup() {",
            "  trap - EXIT HUP INT TERM",
            "  if [ \"$cmux_ssh_auth_group_published\" = 1 ]; then return; fi",
            "  if [ -n \"${cmux_ssh_auth_group_anchor_pid:-}\" ]; then",
            "    /bin/kill -KILL \"$cmux_ssh_auth_group_anchor_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_auth_group_anchor_pid\" 2>/dev/null || true",
            "  fi",
            "  if [ -n \"${cmux_ssh_auth_group_anchor_guard_fd:-}\" ]; then",
            "    exec {cmux_ssh_auth_group_anchor_guard_fd}>&-",
            "    cmux_ssh_auth_group_anchor_guard_fd=",
            "  fi",
            "  if [ -f \"$cmux_ssh_auth_group_dir/rollback-only\" ] || [ -f \"$cmux_ssh_auth_group_dir/handoff-pending\" ]; then",
            "    /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" \"$cmux_ssh_auth_group_anchor_fifo\" 2>/dev/null || true",
            "    return",
            "  fi",
            "  if cmux_ssh_auth_recorded_process_is_live \"$cmux_ssh_auth_group_dir/handoff.owner\"; then",
            "    /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" \"$cmux_ssh_auth_group_anchor_fifo\" 2>/dev/null || true",
            "    return",
            "  fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" \"$cmux_ssh_auth_group_anchor_fifo\" \"$cmux_ssh_auth_group_file\" \"$cmux_ssh_auth_group_cancel_file\" 2>/dev/null || true",
            "  /bin/rmdir \"$cmux_ssh_auth_group_dir\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_group_handoff() {",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_group_anchor_guard_fd:-}\" ]; then",
            "    exec {cmux_ssh_auth_group_anchor_guard_fd}>&-",
            "    cmux_ssh_auth_group_anchor_guard_fd=",
            "  fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_group_signal_exit() {",
            "  cmux_ssh_auth_group_signal_status=\"$1\"",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_publisher_publish_file\" 2>/dev/null || true",
            "  if [ \"$cmux_ssh_auth_group_published\" != 1 ]; then",
            "    cmux_ssh_auth_group_cleanup",
            "    exit \"$cmux_ssh_auth_group_signal_status\"",
            "  fi",
            "  trap - EXIT HUP INT TERM",
            "  exit \"$cmux_ssh_auth_group_signal_status\"",
            "}",
            "cmux_ssh_auth_group_publisher_is_current() {",
            "  cmux_ssh_auth_group_publisher_record=$(/bin/cat -- \"$cmux_ssh_auth_group_publisher_file\" 2>/dev/null || true)",
            "  cmux_ssh_auth_group_recorded_publisher=${cmux_ssh_auth_group_publisher_record%%|*}",
            "  cmux_ssh_auth_group_publisher_remainder=${cmux_ssh_auth_group_publisher_record#*|}",
            "  cmux_ssh_auth_group_recorded_publisher_group=${cmux_ssh_auth_group_publisher_remainder%%|*}",
            "  cmux_ssh_auth_group_recorded_publisher_started=${cmux_ssh_auth_group_publisher_remainder#*|}",
            "  case \"$cmux_ssh_auth_group_recorded_publisher\" in ''|0|*[!0-9]*) return 1 ;; esac",
            "  case \"$cmux_ssh_auth_group_recorded_publisher_group\" in ''|0|*[!0-9]*) return 1 ;; esac",
            "  case \"$cmux_ssh_auth_group_recorded_publisher_started\" in ''|*[!A-Za-z0-9_:]*) return 1 ;; esac",
            "  cmux_ssh_auth_group_current_publisher=$(cmux_ssh_auth_stable_identity \"$cmux_ssh_auth_group_recorded_publisher\")",
            "  [ \"$cmux_ssh_auth_group_current_publisher\" = \"$cmux_ssh_auth_group_recorded_publisher_group|$cmux_ssh_auth_group_recorded_publisher_started\" ]",
            "}",
            "cmux_ssh_auth_group_anchor_wait() {",
            "  cmux_ssh_auth_group_missing_publisher_checks=0",
            "  while [ -s \"$cmux_ssh_auth_group_file\" ]; do",
            "    if cmux_ssh_auth_group_publisher_is_current; then",
            "      cmux_ssh_auth_group_missing_publisher_checks=0",
            "    else",
            "      cmux_ssh_auth_group_missing_publisher_checks=$((cmux_ssh_auth_group_missing_publisher_checks + 1))",
            "      if [ \"$cmux_ssh_auth_group_missing_publisher_checks\" -ge 3 ]; then",
            "        /bin/kill -KILL -- \"-$cmux_ssh_auth_supervisor_group\" >/dev/null 2>&1 || true",
            "        return 0",
            "      fi",
            "    fi",
            "    /bin/sleep 1 || return 1",
            "  done",
            "}",
            "trap 'cmux_ssh_auth_group_cleanup' EXIT",
            "trap 'cmux_ssh_auth_group_signal_exit 129' HUP",
            "trap 'cmux_ssh_auth_group_signal_exit 130' INT",
            "trap 'cmux_ssh_auth_group_signal_exit 143' TERM",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "/usr/bin/mkfifo \"$cmux_ssh_auth_group_anchor_fifo\" || exit 255",
            "exec {cmux_ssh_auth_group_anchor_guard_fd}<> \"$cmux_ssh_auth_group_anchor_fifo\" || exit 255",
            "cmux_ssh_auth_supervisor_group=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o pgid= -p \"$$\" 2>/dev/null | /usr/bin/tr -d '[:space:]')",
            "case \"$cmux_ssh_auth_supervisor_group\" in ''|0|*[!0-9]*) exit 255 ;; esac",
            "if [ \"$cmux_ssh_auth_supervisor_group\" != \"$$\" ]; then exit 255; fi",
            "( trap '' HUP INT TERM; exec {cmux_ssh_auth_group_anchor_guard_fd}>&-; while IFS= read -r cmux_ssh_auth_group_anchor_input; do :; done; cmux_ssh_auth_group_anchor_wait ) < \"$cmux_ssh_auth_group_anchor_fifo\" >/dev/null 2>&1 &",
            "cmux_ssh_auth_group_anchor_pid=$!",
            "cmux_ssh_auth_anchor_identity=$(cmux_ssh_auth_stable_identity \"$cmux_ssh_auth_group_anchor_pid\")",
            "cmux_ssh_auth_anchor_group=${cmux_ssh_auth_anchor_identity%%|*}",
            "cmux_ssh_auth_anchor_started=${cmux_ssh_auth_anchor_identity#*|}",
            "case \"$cmux_ssh_auth_supervisor_group:$cmux_ssh_auth_anchor_group:$cmux_ssh_auth_anchor_started\" in *[!A-Za-z0-9_:]*) exit 255 ;; esac",
            "if [ \"$cmux_ssh_auth_anchor_group\" != \"$cmux_ssh_auth_supervisor_group\" ]; then exit 255; fi",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "cmux_ssh_auth_group_publisher_identity=$(cmux_ssh_auth_identity \"$$\")",
            "cmux_ssh_auth_group_publisher_parent=${cmux_ssh_auth_group_publisher_identity%%|*}",
            "cmux_ssh_auth_group_publisher_remainder=${cmux_ssh_auth_group_publisher_identity#*|}",
            "cmux_ssh_auth_group_publisher_group=${cmux_ssh_auth_group_publisher_remainder%%|*}",
            "cmux_ssh_auth_group_publisher_started=${cmux_ssh_auth_group_publisher_remainder#*|}",
            "case \"$cmux_ssh_auth_group_publisher_parent\" in ''|*[!0-9]*) exit 255 ;; esac",
            "case \"$cmux_ssh_auth_group_publisher_group\" in ''|*[!0-9]*) exit 255 ;; esac",
            "case \"$cmux_ssh_auth_group_publisher_started\" in ''|*[!A-Za-z0-9_:]*) exit 255 ;; esac",
            "cmux_ssh_auth_group_publisher_stable_identity=\"$cmux_ssh_auth_group_publisher_group|$cmux_ssh_auth_group_publisher_started\"",
            "printf '%s|%s\\n' \"$$\" \"$cmux_ssh_auth_group_publisher_stable_identity\" > \"$cmux_ssh_auth_group_publisher_publish_file\" || exit 255",
            "printf '%s|%s|%s\\n' \"$cmux_ssh_auth_group_anchor_pid\" \"$cmux_ssh_auth_anchor_group\" \"$cmux_ssh_auth_anchor_started\" > \"$cmux_ssh_auth_group_publish_file\" || exit 255",
            "/bin/mv -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_file\" || exit 255",
            "/bin/mv -f -- \"$cmux_ssh_auth_group_publisher_publish_file\" \"$cmux_ssh_auth_group_publisher_file\" || exit 255",
            "cmux_ssh_auth_group_published=1",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "unset CMUX_SSH_AUTH_GROUP_DIR",
            "( exec {cmux_ssh_auth_group_anchor_guard_fd}>&-; exec /usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command)) )",
            "cmux_ssh_auth_group_status=$?",
            "cmux_ssh_auth_group_handoff",
            "exit \"$cmux_ssh_auth_group_status\"",
        ].joined(separator: "\n")
        let nestedCommand = "/usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(ownedGroupCommand))"
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
        let script = [
            "umask 077",
            "cmux_ssh_auth_capture_dir=$(/usr/bin/mktemp -d \"${TMPDIR:-/tmp}/cmux-ssh-auth.XXXXXX\") || exit 255",
            "cmux_ssh_auth_capture_state=\"$cmux_ssh_auth_capture_dir/classification\"",
            "cmux_ssh_auth_classifier_fifo=\"$cmux_ssh_auth_capture_dir/classifier.fifo\"",
            "cmux_ssh_auth_classifier_guard_fd=",
            "cmux_ssh_auth_classifier_pid=",
            "cmux_ssh_auth_command_pid=",
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
            "  /bin/rm -f -- \"$cmux_ssh_auth_classifier_fifo\" \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true",
            "  /bin/rmdir \"$cmux_ssh_auth_capture_dir\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_capture_signal_exit() {",
            "  cmux_ssh_auth_capture_signal_status=\"$1\"",
            "  cmux_ssh_auth_capture_signal_name=\"$2\"",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_command_pid:-}\" ]; then",
            "    /bin/kill -\"$cmux_ssh_auth_capture_signal_name\" \"$cmux_ssh_auth_command_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_auth_command_pid\" 2>/dev/null || true",
            "    cmux_ssh_auth_command_pid=",
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
            "( exec {cmux_ssh_auth_classifier_guard_fd}>&-; exec /usr/bin/script -q -F \"$cmux_ssh_auth_classifier_fifo\" \(nestedCommand) <&0 >&2 ) &",
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
