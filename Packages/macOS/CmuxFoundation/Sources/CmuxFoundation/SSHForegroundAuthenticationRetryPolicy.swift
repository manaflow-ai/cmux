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
    /// The immediate authentication PID is a shell wrapper whose descendants own
    /// the classifier, nested PTY, and SSH process. The helper freezes each parent
    /// before discovering its children, then terminates leaves before resuming the
    /// parent so the wrapper cannot spawn new descendants while cleanup descends.
    /// Each stopped parent anchors its child's PID identity during a bounded grace
    /// period. Survivors are revalidated against that parent, frozen, rescanned,
    /// and force-killed. Process-group boundaries are recorded before TERM so a
    /// handler cannot escape by forking a replacement and exiting before the next
    /// scan. Every recursive grace check shares one two-second deadline, while an
    /// isolated child process group is terminated as one unit before recursion.
    /// The caller supplies the authentication root's known wrapper PID so root
    /// validation is not inferred from a potentially reused candidate PID.
    ///
    /// - Returns: A shell function named `cmux_ssh_terminate_auth_process_tree`.
    public func processTreeTerminationShellFunction() -> String {
        """
        cmux_ssh_terminate_auth_process_tree() (
          cmux_ssh_auth_cleanup_has_time() (
            cmux_ssh_auth_cleanup_now=$(/bin/date +%s 2>/dev/null) || exit 1
            case "$cmux_ssh_auth_cleanup_now" in ''|*[!0-9]*) exit 1 ;; esac
            [ "$cmux_ssh_auth_cleanup_now" -lt "$cmux_ssh_auth_cleanup_deadline" ]
          )

          # Snapshot the whole original tree with a SINGLE `ps`, then STOP every member.
          # The chain is already fully spawned before cleanup begins, so one process-table
          # read after freezing the root captures every descendant; the closure is computed
          # in-shell (no per-node fork) and each member is stopped with the builtin `kill`.
          # This matters on a fork-starved shared CI runner, where every extra spawn risks
          # EAGAIN and a silently skipped signal. Returns every PID reached from the root.
          cmux_ssh_snapshot_auth_tree() (
            cmux_ssh_auth_snapshot_root="$1"
            kill -STOP "$cmux_ssh_auth_snapshot_root" >/dev/null 2>&1 || true
            cmux_ssh_auth_snapshot_table=$(/bin/ps -axo pid=,ppid= 2>/dev/null) || cmux_ssh_auth_snapshot_table=""
            cmux_ssh_auth_snapshot_all=" $cmux_ssh_auth_snapshot_root "
            # Repeatedly fold children of already-collected pids into the set until it is
            # closed. Bounded by tree depth; every iteration is pure shell, no subprocess.
            cmux_ssh_auth_snapshot_grew=1
            while [ "$cmux_ssh_auth_snapshot_grew" = 1 ]; do
              cmux_ssh_auth_snapshot_grew=0
              # shellcheck disable=SC2086
              set -- $cmux_ssh_auth_snapshot_table
              while [ "$#" -ge 2 ]; do
                cmux_ssh_auth_snapshot_child="$1"
                cmux_ssh_auth_snapshot_parent="$2"
                shift 2
                case "$cmux_ssh_auth_snapshot_all" in
                  *" $cmux_ssh_auth_snapshot_child "*) continue ;;
                esac
                case "$cmux_ssh_auth_snapshot_all" in
                  *" $cmux_ssh_auth_snapshot_parent "*)
                    cmux_ssh_auth_snapshot_all="$cmux_ssh_auth_snapshot_all$cmux_ssh_auth_snapshot_child "
                    cmux_ssh_auth_snapshot_grew=1
                    ;;
                esac
              done
            done
            for cmux_ssh_auth_snapshot_pid in $cmux_ssh_auth_snapshot_all; do
              kill -STOP "$cmux_ssh_auth_snapshot_pid" >/dev/null 2>&1 || true
            done
            printf '%s' "$cmux_ssh_auth_snapshot_all"
          )

          cmux_ssh_terminate_auth_process_group() (
            cmux_ssh_auth_process_group="$1"
            if [ -z "$cmux_ssh_auth_process_group" ]; then exit 0; fi
            kill -TERM -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1 || true
            while kill -0 -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1 \
              && cmux_ssh_auth_cleanup_has_time; do
              /bin/sleep 0.02
            done
            if kill -0 -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1; then
              kill -KILL -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1 || true
            fi
          )

          cmux_ssh_auth_process_is_original() (
            cmux_ssh_auth_process_pid="$1"
            cmux_ssh_auth_process_parent_pid="$2"
            cmux_ssh_auth_process_snapshot=$(/bin/ps -o ppid= -o state= -p "$cmux_ssh_auth_process_pid" 2>/dev/null) || exit 1
            set -- $cmux_ssh_auth_process_snapshot
            if [ "$#" -lt 2 ] || [ "$1" != "$cmux_ssh_auth_process_parent_pid" ]; then exit 1; fi
            case "$2" in *Z*) exit 1 ;; esac
            kill -0 "$cmux_ssh_auth_process_pid" >/dev/null 2>&1
          )

          cmux_ssh_terminate_auth_process() (
            cmux_ssh_auth_tree_pid="$1"
            cmux_ssh_auth_tree_parent_pid="$2"
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              exit 0
            fi
            if ! cmux_ssh_auth_cleanup_has_time; then
              kill -KILL "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              exit 0
            fi
            if ! kill -STOP "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1; then exit 0; fi
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              exit 0
            fi
            cmux_ssh_auth_tree_process_group=$(/bin/ps -o pgid= -p "$cmux_ssh_auth_tree_pid" 2>/dev/null | /usr/bin/tr -d '[:space:]')
            cmux_ssh_auth_tree_parent_process_group=$(/bin/ps -o pgid= -p "$cmux_ssh_auth_tree_parent_pid" 2>/dev/null | /usr/bin/tr -d '[:space:]')
            cmux_ssh_auth_tree_isolated_process_group=
            case "$cmux_ssh_auth_tree_process_group" in
              ''|0|*[!0-9]*) ;;
              *)
                case "$cmux_ssh_auth_tree_parent_process_group" in
                  ''|0|*[!0-9]*) ;;
                  *)
                    if [ "$cmux_ssh_auth_tree_process_group" != "$cmux_ssh_auth_tree_parent_process_group" ]; then
                      cmux_ssh_auth_tree_isolated_process_group="$cmux_ssh_auth_tree_process_group"
                    fi
                    ;;
                esac
                ;;
            esac
            if [ -n "$cmux_ssh_auth_tree_isolated_process_group" ]; then
              kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              cmux_ssh_terminate_auth_process_group "$cmux_ssh_auth_tree_isolated_process_group"
              exit 0
            fi
            for cmux_ssh_auth_tree_child in $(/usr/bin/pgrep -P "$cmux_ssh_auth_tree_pid" . 2>/dev/null || true); do
              cmux_ssh_terminate_auth_process "$cmux_ssh_auth_tree_child" "$cmux_ssh_auth_tree_pid"
            done
            if ! cmux_ssh_auth_cleanup_has_time; then
              kill -KILL "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              exit 0
            fi

            kill -TERM "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            while cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid" \
              && cmux_ssh_auth_cleanup_has_time; do
              /bin/sleep 0.02
            done
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              exit 0
            fi
            if ! cmux_ssh_auth_cleanup_has_time; then
              kill -KILL "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              exit 0
            fi

            if ! kill -STOP "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1; then
              exit 0
            fi
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              exit 0
            fi
            for cmux_ssh_auth_tree_child in $(/usr/bin/pgrep -P "$cmux_ssh_auth_tree_pid" . 2>/dev/null || true); do
              cmux_ssh_terminate_auth_process "$cmux_ssh_auth_tree_child" "$cmux_ssh_auth_tree_pid"
            done
            if cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              kill -KILL "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            else
              kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            fi
          )

          cmux_ssh_auth_tree_root_pid="$1"
          cmux_ssh_auth_tree_root_parent="$2"
          case "$cmux_ssh_auth_tree_root_pid:$cmux_ssh_auth_tree_root_parent" in
            *[!0-9:]*|:*|*:) exit 0 ;;
          esac
          if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_root_pid" "$cmux_ssh_auth_tree_root_parent"; then
            exit 0
          fi
          # Freeze and snapshot the tree first, before anything that can fork and fail.
          # Liveness then depends only on this snapshot plus the fork-free builtin kill
          # backstop below, never on the graceful walk or the clock succeeding.
          cmux_ssh_auth_tree_snapshot=$(cmux_ssh_snapshot_auth_tree "$cmux_ssh_auth_tree_root_pid")
          # The clock is best-effort: if `date` cannot fork on a starved host, treat the
          # deadline as already lapsed so the walk skips the graceful phase and kills.
          cmux_ssh_auth_cleanup_started_at=$(/bin/date +%s 2>/dev/null)
          case "$cmux_ssh_auth_cleanup_started_at" in
            ''|*[!0-9]*) cmux_ssh_auth_cleanup_deadline=0 ;;
            *) cmux_ssh_auth_cleanup_deadline=$((cmux_ssh_auth_cleanup_started_at + 2)) ;;
          esac
          cmux_ssh_terminate_auth_process "$cmux_ssh_auth_tree_root_pid" "$cmux_ssh_auth_tree_root_parent"
          # Backstop: every member of the frozen original tree that the ordered, deadline-
          # bounded walk did not already reap is force-killed together. The snapshot was
          # taken while the tree was frozen, so a reparent during the walk cannot hide one.
          # shellcheck disable=SC2086
          kill -KILL -- $cmux_ssh_auth_tree_snapshot >/dev/null 2>&1 || true
        )
        """
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
        let nestedCommand = "/usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command))"
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
            "cmux_ssh_auth_capture_state=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-auth.XXXXXX\") || exit 255",
            "cmux_ssh_auth_classifier_fifo=\"$cmux_ssh_auth_capture_state.classifier.fifo\"",
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
            "      kill \"$cmux_ssh_auth_capture_pid\" >/dev/null 2>&1 || true",
            "      wait \"$cmux_ssh_auth_capture_pid\" 2>/dev/null || true",
            "    fi",
            "  done",
            "  /bin/rm -f -- \"$cmux_ssh_auth_classifier_fifo\" \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_capture_signal_exit() {",
            "  cmux_ssh_auth_capture_signal_status=\"$1\"",
            "  cmux_ssh_auth_capture_signal_name=\"$2\"",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_command_pid:-}\" ]; then",
            "    kill -\"$cmux_ssh_auth_capture_signal_name\" \"$cmux_ssh_auth_command_pid\" >/dev/null 2>&1 || true",
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
