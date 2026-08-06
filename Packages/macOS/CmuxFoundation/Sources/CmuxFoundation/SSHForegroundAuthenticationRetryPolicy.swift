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

    /// Builds the final removal command for a reaped authentication attempt's bounded state.
    ///
    /// Callers run this only after the authentication root has exited, when no late
    /// publisher can still require the cancellation marker.
    ///
    /// - Returns: A shell command that removes every file owned by the group-state protocol.
    public func processGroupStateRemovalShellCommand() -> String {
        let fileNames = [
            "identity",
            "identity.new",
            "anchor",
            "cancel",
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
        ]
        let arguments = fileNames
            .map { "\"$CMUX_SSH_AUTH_GROUP_DIR/\($0)\"" }
            .joined(separator: " ")
        return "/bin/rm -f -- \(arguments) 2>/dev/null || true"
    }

    /// Builds the bounded helper that terminates foreground SSH authentication.
    ///
    /// The classifier publishes a signal-resistant anchor in its isolated PTY
    /// process group. Cleanup validates the anchor and group identities, freezes
    /// the bounded descendant closure, then KILLs every owned group. The shared
    /// wrapper PID is KILLed only while its original identity still matches.
    ///
    /// - Returns: Shell functions that terminate the owned group and outer tree.
    public func processTreeTerminationShellFunction() -> String {
        #"""
        cmux_ssh_auth_identity() {
          /usr/bin/env LC_ALL=C LANG=C /bin/ps -o ppid= -o pgid= -o state= -o lstart= -p "$1" 2>/dev/null | \
            /usr/bin/awk 'NF >= 8 && $3 !~ /Z/ {
              cmux_started = $4 "_" $5 "_" $6 "_" $7 "_" $8
              print $1 "|" $2 "|" cmux_started
            }'
        }

        \#(ownedProcessGroupTerminationShellFunctions())

        cmux_ssh_launch_owned_auth_group_reaper() {
          cmux_ssh_auth_reaper_group_dir="$1"
          if [ ! -s "$cmux_ssh_auth_reaper_group_dir/identity" ]; then return 0; fi
          cmux_ssh_auth_reaper_lock="$cmux_ssh_auth_reaper_group_dir/reaper.lock"
          /bin/mkdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || return 0
          (
            trap '' HUP INT TERM
            CMUX_SSH_AUTH_GROUP_DIR="$cmux_ssh_auth_reaper_group_dir"
            export CMUX_SSH_AUTH_GROUP_DIR
            cmux_ssh_auth_reaper_attempt=0
            cmux_ssh_auth_reaper_delay=1
            while [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ] && \
              [ "$cmux_ssh_auth_reaper_attempt" -lt 3 ]; do
              cmux_ssh_auth_reaper_attempt=$((cmux_ssh_auth_reaper_attempt + 1))
              cmux_ssh_terminate_owned_auth_group
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
            else
              /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed" \
                "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed.new" 2>/dev/null || true
            fi
            /bin/rmdir "$cmux_ssh_auth_reaper_lock" 2>/dev/null || true
            if [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; then
              /bin/rmdir "$CMUX_SSH_AUTH_GROUP_DIR" 2>/dev/null || true
            fi
          ) </dev/null >/dev/null 2>&1 &
        }

        cmux_ssh_terminate_owned_auth_group() (
          cmux_ssh_auth_group_dir="${CMUX_SSH_AUTH_GROUP_DIR:-}"
          if [ -z "$cmux_ssh_auth_group_dir" ]; then exit 0; fi
          cmux_ssh_auth_expected_dir_identity="$(/usr/bin/id -u):700"
          cmux_ssh_auth_observed_dir_identity=$(/usr/bin/stat -f '%u:%Lp' "$cmux_ssh_auth_group_dir" 2>/dev/null || true)
          if [ "$cmux_ssh_auth_observed_dir_identity" != "$cmux_ssh_auth_expected_dir_identity" ]; then exit 0; fi
          cmux_ssh_auth_group_file="$cmux_ssh_auth_group_dir/identity"
          cmux_ssh_auth_group_anchor_fifo="$cmux_ssh_auth_group_dir/anchor"
          cmux_ssh_auth_group_publish_file="$cmux_ssh_auth_group_dir/identity.new"
          cmux_ssh_auth_group_cancel_file="$cmux_ssh_auth_group_dir/cancel"
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
          cmux_ssh_auth_reaper_failed="$cmux_ssh_auth_group_dir/reaper.failed"
          cmux_ssh_auth_reaper_failed_publish="$cmux_ssh_auth_group_dir/reaper.failed.new"
          cmux_ssh_auth_remove_cancel=0
          cmux_ssh_auth_cleanup_started=0
          cmux_ssh_auth_cleanup_complete=0
          cmux_ssh_auth_preserve_group_state=0
          cmux_ssh_auth_group_state_cleanup() {
            if [ "$cmux_ssh_auth_cleanup_started" = 1 ] && \
              [ "$cmux_ssh_auth_cleanup_complete" != 1 ]; then
              if cmux_ssh_auth_deadline_allows_work && \
                cmux_ssh_auth_force_owned_processes >/dev/null 2>&1; then
                cmux_ssh_auth_cleanup_complete=1
              else
                cmux_ssh_auth_deadline_millis="$cmux_ssh_auth_hard_deadline_millis"
                if cmux_ssh_auth_force_frozen_processes >/dev/null 2>&1; then
                  cmux_ssh_auth_cleanup_complete=1
                else
                  cmux_ssh_auth_preserve_group_state=1
                fi
                cmux_ssh_auth_resume_signaled_processes
              fi
            fi
            if [ "$cmux_ssh_auth_preserve_group_state" = 1 ]; then return; fi
            /bin/rm -f -- "$cmux_ssh_auth_group_file" "$cmux_ssh_auth_group_anchor_fifo" \
              "$cmux_ssh_auth_group_publish_file" "$cmux_ssh_auth_process_snapshot" \
              "$cmux_ssh_auth_poststop_snapshot" \
              "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_next_owned_processes" \
              "$cmux_ssh_auth_owned_groups" "$cmux_ssh_auth_next_owned_groups" \
              "$cmux_ssh_auth_resume_groups" "$cmux_ssh_auth_frozen_processes" \
              "$cmux_ssh_auth_individual_processes" "$cmux_ssh_auth_ordered_processes" \
              "$cmux_ssh_auth_signaled_groups" "$cmux_ssh_auth_signaled_processes" \
              "$cmux_ssh_auth_reaper_failed" "$cmux_ssh_auth_reaper_failed_publish" \
              2>/dev/null || true
            if [ "$cmux_ssh_auth_remove_cancel" = 1 ]; then
              /bin/rm -f -- "$cmux_ssh_auth_group_cancel_file" 2>/dev/null || true
            fi
            /bin/rmdir "$cmux_ssh_auth_group_dir" 2>/dev/null || true
          }
          trap 'cmux_ssh_auth_group_state_cleanup' EXIT
          if [ ! -d "$cmux_ssh_auth_group_dir" ]; then exit 0; fi
          : > "$cmux_ssh_auth_group_cancel_file" 2>/dev/null || exit 0

          cmux_ssh_auth_group_attempt=0
          while [ -d "$cmux_ssh_auth_group_dir" ] && [ ! -s "$cmux_ssh_auth_group_file" ] && \
            [ "$cmux_ssh_auth_group_attempt" -lt 200 ]; do
            /bin/sleep 0.01
            cmux_ssh_auth_group_attempt=$((cmux_ssh_auth_group_attempt + 1))
          done
          if [ ! -s "$cmux_ssh_auth_group_file" ]; then exit 0; fi

          cmux_ssh_auth_group_identity=$(/bin/cat -- "$cmux_ssh_auth_group_file" 2>/dev/null || true)
          cmux_ssh_auth_group_anchor=${cmux_ssh_auth_group_identity%%|*}
          cmux_ssh_auth_group_remainder=${cmux_ssh_auth_group_identity#*|}
          cmux_ssh_auth_owned_group=${cmux_ssh_auth_group_remainder%%|*}
          cmux_ssh_auth_anchor_started=${cmux_ssh_auth_group_remainder#*|}
          case "$cmux_ssh_auth_group_anchor:$cmux_ssh_auth_owned_group:$cmux_ssh_auth_anchor_started" in
            *[!A-Za-z0-9_:]*|:*|*:) exit 0 ;;
          esac

          cmux_ssh_auth_caller_group=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o pgid= -p "$$" 2>/dev/null | /usr/bin/tr -d '[:space:]')
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

          cmux_ssh_auth_remove_cancel=1
          : > "$cmux_ssh_auth_owned_processes" || exit 0
          : > "$cmux_ssh_auth_frozen_processes" || exit 0
          : > "$cmux_ssh_auth_signaled_groups" || exit 0
          : > "$cmux_ssh_auth_signaled_processes" || exit 0
          cmux_ssh_auth_cleanup_started_millis="$(cmux_ssh_auth_now_millis)" || exit 0
          case "$cmux_ssh_auth_cleanup_started_millis" in ''|*[!0-9]*) exit 0 ;; esac
          cmux_ssh_auth_deadline_millis=$((cmux_ssh_auth_cleanup_started_millis + 500))
          cmux_ssh_auth_hard_deadline_millis=$((cmux_ssh_auth_cleanup_started_millis + 2000))
          cmux_ssh_auth_cleanup_started=1
          cmux_ssh_auth_freeze_attempt=0
          while [ "$cmux_ssh_auth_freeze_attempt" -lt 4 ]; do
            cmux_ssh_auth_deadline_allows_work || exit 0
            cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" || exit 0
            cmux_ssh_auth_expand_owned_processes || exit 0
            cmux_ssh_auth_freeze_owned_processes || exit 0
            cmux_ssh_auth_freeze_attempt=$((cmux_ssh_auth_freeze_attempt + 1))
          done
          cmux_ssh_auth_force_owned_processes || exit 0
          cmux_ssh_auth_cleanup_complete=1
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

          cmux_ssh_terminate_owned_auth_group
          if [ -z "$cmux_ssh_auth_root_identity" ]; then exit 0; fi
          cmux_ssh_auth_current_root_identity=$(cmux_ssh_auth_identity "$cmux_ssh_auth_root_pid")
          if [ "$cmux_ssh_auth_current_root_identity" = "$cmux_ssh_auth_root_identity" ]; then
            kill -KILL "$cmux_ssh_auth_root_pid" >/dev/null 2>&1 || true
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
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_anchor_fifo\" \"$cmux_ssh_auth_group_file\" \"$cmux_ssh_auth_group_cancel_file\" 2>/dev/null || true",
            "  /bin/rmdir \"$cmux_ssh_auth_group_dir\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_group_handoff() {",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_group_anchor_guard_fd:-}\" ]; then",
            "    exec {cmux_ssh_auth_group_anchor_guard_fd}>&-",
            "    cmux_ssh_auth_group_anchor_guard_fd=",
            "  fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_group_signal_exit() {",
            "  cmux_ssh_auth_group_signal_status=\"$1\"",
            "  /bin/rm -f -- \"$cmux_ssh_auth_group_publish_file\" 2>/dev/null || true",
            "  if [ \"$cmux_ssh_auth_group_published\" != 1 ]; then",
            "    cmux_ssh_auth_group_cleanup",
            "    exit \"$cmux_ssh_auth_group_signal_status\"",
            "  fi",
            "  trap - EXIT HUP INT TERM",
            "  exit \"$cmux_ssh_auth_group_signal_status\"",
            "}",
            "trap 'cmux_ssh_auth_group_cleanup' EXIT",
            "trap 'cmux_ssh_auth_group_signal_exit 129' HUP",
            "trap 'cmux_ssh_auth_group_signal_exit 130' INT",
            "trap 'cmux_ssh_auth_group_signal_exit 143' TERM",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "/usr/bin/mkfifo \"$cmux_ssh_auth_group_anchor_fifo\" || exit 255",
            "exec {cmux_ssh_auth_group_anchor_guard_fd}<> \"$cmux_ssh_auth_group_anchor_fifo\" || exit 255",
            "( trap '' HUP INT TERM; while IFS= read -r cmux_ssh_auth_group_anchor_input; do :; done ) < \"$cmux_ssh_auth_group_anchor_fifo\" >/dev/null 2>&1 &",
            "cmux_ssh_auth_group_anchor_pid=$!",
            "cmux_ssh_auth_supervisor_group=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o pgid= -p \"$$\" 2>/dev/null | /usr/bin/tr -d '[:space:]')",
            "cmux_ssh_auth_anchor_identity=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o pgid= -o state= -o lstart= -p \"$cmux_ssh_auth_group_anchor_pid\" 2>/dev/null | /usr/bin/awk 'NF >= 7 && $2 !~ /Z/ { print $1 \"|\" $3 \"_\" $4 \"_\" $5 \"_\" $6 \"_\" $7 }')",
            "cmux_ssh_auth_anchor_group=${cmux_ssh_auth_anchor_identity%%|*}",
            "cmux_ssh_auth_anchor_started=${cmux_ssh_auth_anchor_identity#*|}",
            "case \"$cmux_ssh_auth_supervisor_group:$cmux_ssh_auth_anchor_group:$cmux_ssh_auth_anchor_started\" in *[!A-Za-z0-9_:]*) exit 255 ;; esac",
            "if [ \"$cmux_ssh_auth_supervisor_group\" != \"$$\" ] || [ \"$cmux_ssh_auth_anchor_group\" != \"$cmux_ssh_auth_supervisor_group\" ]; then exit 255; fi",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "printf '%s|%s|%s\\n' \"$cmux_ssh_auth_group_anchor_pid\" \"$cmux_ssh_auth_anchor_group\" \"$cmux_ssh_auth_anchor_started\" > \"$cmux_ssh_auth_group_publish_file\" || exit 255",
            "/bin/mv -f -- \"$cmux_ssh_auth_group_publish_file\" \"$cmux_ssh_auth_group_file\" || exit 255",
            "cmux_ssh_auth_group_published=1",
            "if [ -e \"$cmux_ssh_auth_group_cancel_file\" ]; then exit 143; fi",
            "unset CMUX_SSH_AUTH_GROUP_DIR",
            "/usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command))",
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
