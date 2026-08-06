internal import Foundation

/// Classifies foreground SSH authentication failures without hiding interactive
/// prompts or retrying permanent authentication and configuration errors.
///
/// OpenSSH uses status 255 for both transport outages and permanent failures.
/// The persistent PTY wrappers therefore need stderr context before deciding
/// whether an initial authentication attempt belongs in their reconnect loop.
public struct SSHForegroundAuthenticationRetryPolicy: Sendable {
    /// Maximum consecutive transport failures before foreground auth surfaces the outage.
    public let maximumConsecutiveTransientFailures = 20

    /// Internal shell status for a status-255 failure with no recognized diagnostic.
    ///
    /// Callers surface this as 255 without retrying. Only a recognized transient
    /// transport diagnostic enters the foreground-authentication reconnect loop.
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
    /// scan. Every recursive grace check shares one two-second deadline. Once it
    /// expires, the helper still walks the frozen remaining subtree without any
    /// further waits and force-kills each identity-checked descendant. An isolated
    /// child process group is terminated as one unit before recursion.
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

          cmux_ssh_terminate_auth_process_group() (
            cmux_ssh_auth_process_group="$1"
            if [ -z "$cmux_ssh_auth_process_group" ]; then exit 0; fi
            /bin/kill -TERM -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1 || true
            while /bin/kill -0 -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1 \
              && cmux_ssh_auth_cleanup_has_time; do
              /bin/sleep 0.02
            done
            if /bin/kill -0 -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1; then
              /bin/kill -KILL -- "-$cmux_ssh_auth_process_group" >/dev/null 2>&1 || true
            fi
          )

          cmux_ssh_auth_process_is_original() (
            cmux_ssh_auth_process_pid="$1"
            cmux_ssh_auth_process_parent_pid="$2"
            cmux_ssh_auth_process_snapshot=$(/bin/ps -o ppid= -o state= -p "$cmux_ssh_auth_process_pid" 2>/dev/null) || exit 1
            if ! printf '%s\n' "$cmux_ssh_auth_process_snapshot" | (
              IFS=' ' read -r cmux_ssh_auth_process_observed_parent cmux_ssh_auth_process_state
              if [ "$cmux_ssh_auth_process_observed_parent" != "$cmux_ssh_auth_process_parent_pid" ]; then exit 1; fi
              case "$cmux_ssh_auth_process_state" in ''|*Z*) exit 1 ;; esac
            ); then
              exit 1
            fi
            /bin/kill -0 "$cmux_ssh_auth_process_pid" >/dev/null 2>&1
          )

          cmux_ssh_stop_auth_tree_members() (
            printf '%s\n' "$1" | (
              cmux_ssh_auth_tree_all_stopped=1
              while IFS=' ' read -r cmux_ssh_auth_tree_member_depth cmux_ssh_auth_tree_member_pid cmux_ssh_auth_tree_member_state; do
                if [ -z "$cmux_ssh_auth_tree_member_pid" ]; then continue; fi
                case "$cmux_ssh_auth_tree_member_state" in *T*) ;; *) cmux_ssh_auth_tree_all_stopped= ;; esac
                kill -STOP "$cmux_ssh_auth_tree_member_pid" >/dev/null 2>&1 || true
              done
              [ -n "$cmux_ssh_auth_tree_all_stopped" ]
            )
          )

          cmux_ssh_resume_auth_tree_members() (
            printf '%s\n' "$1" | while IFS=' ' read -r cmux_ssh_auth_tree_member_depth cmux_ssh_auth_tree_member_pid cmux_ssh_auth_tree_member_state; do
              if [ -n "$cmux_ssh_auth_tree_member_pid" ]; then
                kill -CONT "$cmux_ssh_auth_tree_member_pid" >/dev/null 2>&1 || true
              fi
            done
          )

          cmux_ssh_kill_auth_tree_members() (
            printf '%s\n' "$1" | while IFS=' ' read -r cmux_ssh_auth_tree_member_depth cmux_ssh_auth_tree_member_pid cmux_ssh_auth_tree_member_state; do
              if [ -n "$cmux_ssh_auth_tree_member_pid" ]; then
                kill -KILL "$cmux_ssh_auth_tree_member_pid" >/dev/null 2>&1 || true
                kill -CONT "$cmux_ssh_auth_tree_member_pid" >/dev/null 2>&1 || true
              fi
            done
          )

          cmux_ssh_force_terminate_auth_process() (
            cmux_ssh_auth_tree_pid="$1"
            cmux_ssh_auth_tree_parent_pid="$2"
            cmux_ssh_auth_tree_freeze_attempt=0
            cmux_ssh_auth_tree_members=
            cmux_ssh_auth_tree_frozen_members=
            while [ "$cmux_ssh_auth_tree_freeze_attempt" -lt 8 ]; do
              # Freeze parent-first, then resnapshot to catch children spawned before STOP landed.
              cmux_ssh_auth_tree_snapshot=$(/bin/ps -axo pid=,ppid=,state= 2>/dev/null) || {
                cmux_ssh_resume_auth_tree_members "$cmux_ssh_auth_tree_frozen_members"
                exit 0
              }
              cmux_ssh_auth_tree_next_members=$(printf '%s\n' "$cmux_ssh_auth_tree_snapshot" | /usr/bin/awk \
                -v cmux_root="$cmux_ssh_auth_tree_pid" \
                -v cmux_root_parent="$cmux_ssh_auth_tree_parent_pid" '
                  {
                    cmux_parent[$1] = $2
                    cmux_state[$1] = $3
                    cmux_process[$1] = 1
                  }
                  END {
                    if (!(cmux_root in cmux_process) ||
                        cmux_parent[cmux_root] != cmux_root_parent ||
                        cmux_state[cmux_root] ~ /Z/) {
                      exit
                    }
                    cmux_depth[cmux_root] = 0
                    cmux_discovered = 1
                    while (cmux_discovered) {
                      cmux_discovered = 0
                      for (cmux_candidate in cmux_process) {
                        if (cmux_candidate in cmux_depth || cmux_state[cmux_candidate] ~ /Z/) {
                          continue
                        }
                        cmux_candidate_parent = cmux_parent[cmux_candidate]
                        if (cmux_candidate_parent in cmux_depth) {
                          cmux_depth[cmux_candidate] = cmux_depth[cmux_candidate_parent] + 1
                          cmux_discovered = 1
                        }
                      }
                    }
                    for (cmux_candidate in cmux_depth) {
                      print cmux_depth[cmux_candidate], cmux_candidate, cmux_state[cmux_candidate]
                    }
                  }
                ' | /usr/bin/sort -n -k1,1 -k2,2n)
              if [ -z "$cmux_ssh_auth_tree_next_members" ]; then
                cmux_ssh_resume_auth_tree_members "$cmux_ssh_auth_tree_frozen_members"
                exit 0
              fi
              cmux_ssh_auth_tree_members="$cmux_ssh_auth_tree_next_members"
              cmux_ssh_auth_tree_frozen_members="$cmux_ssh_auth_tree_members"
              if cmux_ssh_stop_auth_tree_members "$cmux_ssh_auth_tree_members"; then break; fi
              cmux_ssh_auth_tree_freeze_attempt=$((cmux_ssh_auth_tree_freeze_attempt + 1))
            done

            cmux_ssh_auth_tree_kill_order=$(printf '%s\n' "$cmux_ssh_auth_tree_members" | /usr/bin/sort -nr -k1,1 -k2,2nr) || {
              cmux_ssh_resume_auth_tree_members "$cmux_ssh_auth_tree_frozen_members"
              exit 0
            }
            if [ -z "$cmux_ssh_auth_tree_kill_order" ]; then
              cmux_ssh_resume_auth_tree_members "$cmux_ssh_auth_tree_frozen_members"
              exit 0
            fi
            cmux_ssh_kill_auth_tree_members "$cmux_ssh_auth_tree_kill_order"
          )

          cmux_ssh_terminate_auth_process() (
            cmux_ssh_auth_tree_pid="$1"
            cmux_ssh_auth_tree_parent_pid="$2"
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              exit 0
            fi
            if ! cmux_ssh_auth_cleanup_has_time; then
              exit "$cmux_ssh_auth_cleanup_expired_status"
            fi
            if ! /bin/kill -STOP "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1; then exit 0; fi
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
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
              /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              cmux_ssh_terminate_auth_process_group "$cmux_ssh_auth_tree_isolated_process_group"
              exit 0
            fi
            for cmux_ssh_auth_tree_child in $(/usr/bin/pgrep -P "$cmux_ssh_auth_tree_pid" . 2>/dev/null || true); do
              cmux_ssh_terminate_auth_process "$cmux_ssh_auth_tree_child" "$cmux_ssh_auth_tree_pid" || {
                cmux_ssh_auth_tree_child_status=$?
                if [ "$cmux_ssh_auth_tree_child_status" -eq "$cmux_ssh_auth_cleanup_expired_status" ]; then
                  /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
                  exit "$cmux_ssh_auth_cleanup_expired_status"
                fi
              }
            done
            if ! cmux_ssh_auth_cleanup_has_time; then
              /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              exit "$cmux_ssh_auth_cleanup_expired_status"
            fi

            /bin/kill -TERM "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            while cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid" \
              && cmux_ssh_auth_cleanup_has_time; do
              /bin/sleep 0.02
            done
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              exit 0
            fi
            if ! cmux_ssh_auth_cleanup_has_time; then
              exit "$cmux_ssh_auth_cleanup_expired_status"
            fi

            if ! /bin/kill -STOP "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1; then
              exit 0
            fi
            if ! cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              exit 0
            fi
            for cmux_ssh_auth_tree_child in $(/usr/bin/pgrep -P "$cmux_ssh_auth_tree_pid" . 2>/dev/null || true); do
              cmux_ssh_terminate_auth_process "$cmux_ssh_auth_tree_child" "$cmux_ssh_auth_tree_pid" || {
                cmux_ssh_auth_tree_child_status=$?
                if [ "$cmux_ssh_auth_tree_child_status" -eq "$cmux_ssh_auth_cleanup_expired_status" ]; then
                  /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
                  exit "$cmux_ssh_auth_cleanup_expired_status"
                fi
              }
            done
            if cmux_ssh_auth_process_is_original "$cmux_ssh_auth_tree_pid" "$cmux_ssh_auth_tree_parent_pid"; then
              /bin/kill -KILL "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
              /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            else
              /bin/kill -CONT "$cmux_ssh_auth_tree_pid" >/dev/null 2>&1 || true
            fi
          )

          cmux_ssh_auth_tree_root_pid="$1"
          cmux_ssh_auth_tree_root_parent="$2"
          case "$cmux_ssh_auth_tree_root_pid:$cmux_ssh_auth_tree_root_parent" in
            *[!0-9:]*|:*|*:) exit 0 ;;
          esac
          cmux_ssh_auth_cleanup_started_at=$(/bin/date +%s 2>/dev/null) || exit 0
          case "$cmux_ssh_auth_cleanup_started_at" in ''|*[!0-9]*) exit 0 ;; esac
          cmux_ssh_auth_cleanup_deadline=$((cmux_ssh_auth_cleanup_started_at + 2))
          # Unwind stopped ancestors before one root-level force scan of the remaining subtree.
          cmux_ssh_auth_cleanup_expired_status=90
          cmux_ssh_auth_tree_status=0
          cmux_ssh_terminate_auth_process "$cmux_ssh_auth_tree_root_pid" "$cmux_ssh_auth_tree_root_parent" || \
            cmux_ssh_auth_tree_status=$?
          if [ "$cmux_ssh_auth_tree_status" -eq "$cmux_ssh_auth_cleanup_expired_status" ]; then
            cmux_ssh_force_terminate_auth_process "$cmux_ssh_auth_tree_root_pid" "$cmux_ssh_auth_tree_root_parent"
          fi
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
            "      /bin/kill \"$cmux_ssh_auth_capture_pid\" >/dev/null 2>&1 || true",
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
