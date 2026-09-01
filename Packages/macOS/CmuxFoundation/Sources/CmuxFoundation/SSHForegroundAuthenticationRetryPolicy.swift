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
    /// The helper takes a process-table snapshot, indexes parent/child edges in
    /// one pass, and freezes the reachable tree with shell-builtin signals. Each
    /// accepted record carries its PID, process group, and `ps lstart` identity.
    /// A second snapshot must confirm the identity and stopped state before the
    /// helper sends `SIGKILL`. After `SIGTERM`, descendants and exclusive process
    /// groups are re-discovered so a handler-spawned replacement remains owned.
    /// Failed snapshots never trigger an unverified kill; the EXIT path resumes
    /// only identities that can still be matched. This keeps cleanup bounded when
    /// the runner cannot fork and avoids killing a reused PID.
    ///
    /// - Returns: A shell function named `cmux_ssh_terminate_auth_process_tree`.
    public func processTreeTerminationShellFunction() -> String {
        #"""
        cmux_ssh_terminate_auth_process_tree() (
          cmux_ssh_auth_tree_root_pid="$1"
          cmux_ssh_auth_tree_root_parent="$2"
          case "$cmux_ssh_auth_tree_root_pid:$cmux_ssh_auth_tree_root_parent" in
            *[!0-9:]*|:*|*:) exit 0 ;;
          esac

          # SECONDS is provided by the /bin/sh used by the generated launchers
          # and avoids one fork per deadline check. The pass limits below are a
          # second bound if an older shell does not update it.
          SECONDS=0
          cmux_ssh_auth_cleanup_complete=0
          cmux_ssh_auth_cleanup_has_time() {
            [ "${SECONDS:-0}" -lt 2 ]
          }

          umask 077
          cmux_ssh_auth_state_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmux-ssh-auth-tree.XXXXXX") || exit 0
          cmux_ssh_auth_snapshot="$cmux_ssh_auth_state_dir/snapshot"
          cmux_ssh_auth_members="$cmux_ssh_auth_state_dir/members"
          cmux_ssh_auth_pending="$cmux_ssh_auth_state_dir/pending"
          cmux_ssh_auth_owned="$cmux_ssh_auth_state_dir/owned"
          cmux_ssh_auth_groups="$cmux_ssh_auth_state_dir/groups"
          cmux_ssh_auth_live="$cmux_ssh_auth_state_dir/live"
          cmux_ssh_auth_term="$cmux_ssh_auth_state_dir/term"
          cmux_ssh_auth_caller_group_file="$cmux_ssh_auth_state_dir/caller-group"
          : > "$cmux_ssh_auth_owned" || exit 0
          : > "$cmux_ssh_auth_pending" || exit 0

          cmux_ssh_auth_take_snapshot() {
            /bin/ps -axo pid=,ppid=,pgid=,state=,lstart= > "$cmux_ssh_auth_snapshot" 2>/dev/null
          }

          cmux_ssh_auth_extract_tree() {
            : > "$cmux_ssh_auth_members"
            : > "$cmux_ssh_auth_groups"
            /usr/bin/awk \
              -v cmux_root="$cmux_ssh_auth_tree_root_pid" \
              -v cmux_root_parent="$cmux_ssh_auth_tree_root_parent" \
              -v cmux_caller_group_file="$cmux_ssh_auth_caller_group_file" '
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
                  cmux_caller_group = cmux_group[cmux_root_parent]
                  if (cmux_caller_group != "") print cmux_caller_group > cmux_caller_group_file
                }
              ' "$cmux_ssh_auth_snapshot" > "$cmux_ssh_auth_members"
            cmux_ssh_auth_extract_status=$?
            if [ "$cmux_ssh_auth_extract_status" -ne 0 ]; then return "$cmux_ssh_auth_extract_status"; fi
            cmux_ssh_auth_caller_group=""
            if [ -s "$cmux_ssh_auth_caller_group_file" ]; then
              IFS= read -r cmux_ssh_auth_caller_group < "$cmux_ssh_auth_caller_group_file"
            fi
            /usr/bin/awk -v cmux_caller_group="$cmux_ssh_auth_caller_group" '
              FILENAME == ARGV[1] { cmux_tree[$2] = 1; next }
              NF >= 9 {
                cmux_group = $3
                cmux_pid = $1
                if ($4 ~ /Z/) next
                cmux_total[cmux_group]++
                if (cmux_pid in cmux_tree) cmux_inside[cmux_group]++
              }
              END {
                for (cmux_group in cmux_total) {
                  if (cmux_group != "" && cmux_group != "0" &&
                      cmux_group != cmux_caller_group &&
                      cmux_total[cmux_group] == cmux_inside[cmux_group]) print cmux_group
                }
              }
            ' "$cmux_ssh_auth_members" "$cmux_ssh_auth_snapshot" > "$cmux_ssh_auth_groups"
          }

          cmux_ssh_auth_append_pending() {
            while IFS= read -r cmux_ssh_auth_pending_line; do
              [ -n "$cmux_ssh_auth_pending_line" ] || continue
              printf '%s\n' "$cmux_ssh_auth_pending_line" >> "$cmux_ssh_auth_owned" || return 1
            done < "$cmux_ssh_auth_pending"
            : > "$cmux_ssh_auth_pending"
          }

          cmux_ssh_auth_resume_file() {
            cmux_ssh_auth_resume_path="$1"
            [ -s "$cmux_ssh_auth_resume_path" ] || return 0
            cmux_ssh_auth_take_snapshot || return 0
            cmux_ssh_auth_resume_pids=$(
              /usr/bin/awk '
                FILENAME == ARGV[1] {
                  cmux_expected[$2 SUBSEP $4 SUBSEP $6] = 1
                  next
                }
                NF >= 9 {
                  cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                  if (($1 SUBSEP $3 SUBSEP cmux_started) in cmux_expected && $4 !~ /Z/) print $1
                }
              ' "$cmux_ssh_auth_resume_path" "$cmux_ssh_auth_snapshot"
            ) || return 0
            for cmux_ssh_auth_resume_pid in $cmux_ssh_auth_resume_pids; do
              case "$cmux_ssh_auth_resume_pid" in ''|*[!0-9]*) continue ;; esac
              kill -CONT "$cmux_ssh_auth_resume_pid" >/dev/null 2>&1 || true
            done
          }

          cmux_ssh_auth_cleanup() {
            trap - EXIT HUP INT TERM
            if [ "$cmux_ssh_auth_cleanup_complete" != 1 ]; then
              cmux_ssh_auth_resume_file "$cmux_ssh_auth_pending"
              cmux_ssh_auth_resume_file "$cmux_ssh_auth_owned"
            fi
            /bin/rm -f "$cmux_ssh_auth_snapshot" "$cmux_ssh_auth_members" \
              "$cmux_ssh_auth_pending" "$cmux_ssh_auth_owned" "$cmux_ssh_auth_groups" \
              "$cmux_ssh_auth_live" "$cmux_ssh_auth_term" "$cmux_ssh_auth_caller_group_file" \
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
          cmux_ssh_auth_freeze_attempt=0
          cmux_ssh_auth_tree_frozen=0
          while [ "$cmux_ssh_auth_freeze_attempt" -lt 4 ] && cmux_ssh_auth_cleanup_has_time; do
            : > "$cmux_ssh_auth_pending"
            while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
              case "$cmux_pid:$cmux_parent:$cmux_group:$cmux_started" in
                *[!0-9A-Za-z_:]*|:*|*:) continue ;;
              esac
              # Only successful STOP calls enter the pending ownership journal.
              if kill -STOP "$cmux_pid" >/dev/null 2>&1; then
                printf '%s %s %s %s %s %s\n' \
                  "$cmux_depth" "$cmux_pid" "$cmux_parent" "$cmux_group" "$cmux_state" "$cmux_started" \
                  >> "$cmux_ssh_auth_pending" || exit 0
              fi
            done < "$cmux_ssh_auth_members"
            cmux_ssh_auth_append_pending || exit 0

            if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_tree; then break; fi
            if /usr/bin/awk '
                FILENAME == ARGV[1] { cmux_owned[$2 SUBSEP $4 SUBSEP $6] = 1; next }
                $5 !~ /Z/ && ($2 SUBSEP $4 SUBSEP $6) in cmux_owned && $5 ~ /T/ { next }
                $5 !~ /Z/ { exit 1 }
              ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_members"; then
              cmux_ssh_auth_tree_frozen=1
              break
            fi
            cmux_ssh_auth_freeze_attempt=$((cmux_ssh_auth_freeze_attempt + 1))
          done
          [ "$cmux_ssh_auth_tree_frozen" = 1 ] || exit 0

          # Signal leaves first. This preserves TERM handlers that restore the
          # terminal or launch a short-lived replacement process.
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
          ' "$cmux_ssh_auth_owned" > "$cmux_ssh_auth_term" || exit 0
          while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
            case "$cmux_pid" in ''|*[!0-9]*) continue ;; esac
            kill -TERM "$cmux_pid" >/dev/null 2>&1 || true
            kill -CONT "$cmux_pid" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_term"
          /bin/sleep 0.20 >/dev/null 2>&1 || true

          # Rebuild ownership from exact identities, exclusive groups, and
          # descendants. This catches a replacement that outlives its parent.
          cmux_ssh_auth_extract_owned() {
            : > "$cmux_ssh_auth_live"
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                cmux_owned_identity[$2 SUBSEP $4 SUBSEP $6] = 1
                next
              }
              FILENAME == ARGV[2] { cmux_exclusive_group[$1] = 1; next }
              NF >= 9 {
                cmux_pid = $1
                cmux_parent[cmux_pid] = $2
                cmux_group[cmux_pid] = $3
                cmux_state[cmux_pid] = $4
                cmux_started[cmux_pid] = $5 "_" $6 "_" $7 "_" $8 "_" $9
                cmux_row[cmux_pid] = cmux_pid " " $2 " " $3 " " $4 " " cmux_started[cmux_pid]
                cmux_process[cmux_pid] = 1
                cmux_children[$2] = cmux_children[$2] " " cmux_pid
                if ((cmux_pid SUBSEP $3 SUBSEP cmux_started[cmux_pid]) in cmux_owned_identity ||
                    $3 in cmux_exclusive_group) {
                  cmux_seen[cmux_pid] = 1
                  cmux_queue[++cmux_queue_tail] = cmux_pid
                  cmux_depth[cmux_pid] = 0
                }
              }
              END {
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
            ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_groups" "$cmux_ssh_auth_snapshot" > "$cmux_ssh_auth_live"
          }

          cmux_ssh_auth_force_attempt=0
          cmux_ssh_auth_force_frozen=0
          while [ "$cmux_ssh_auth_force_attempt" -lt 4 ] && cmux_ssh_auth_cleanup_has_time; do
            if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_owned; then break; fi
            if [ ! -s "$cmux_ssh_auth_live" ]; then
              cmux_ssh_auth_force_frozen=1
              break
            fi
            : > "$cmux_ssh_auth_pending"
            while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
              case "$cmux_pid:$cmux_parent:$cmux_group:$cmux_started" in
                *[!0-9A-Za-z_:]*|:*|*:) continue ;;
              esac
              if kill -STOP "$cmux_pid" >/dev/null 2>&1; then
                printf '%s %s %s %s %s %s\n' \
                  "$cmux_depth" "$cmux_pid" "$cmux_parent" "$cmux_group" "$cmux_state" "$cmux_started" \
                  >> "$cmux_ssh_auth_pending" || exit 0
              fi
            done < "$cmux_ssh_auth_live"
            cmux_ssh_auth_append_pending || exit 0
            if ! cmux_ssh_auth_take_snapshot || ! cmux_ssh_auth_extract_owned; then break; fi
            if /usr/bin/awk '
                FILENAME == ARGV[1] { cmux_owned[$2 SUBSEP $4 SUBSEP $6] = 1; next }
                $5 !~ /Z/ && ($2 SUBSEP $4 SUBSEP $6) in cmux_owned && $5 ~ /T/ { next }
                $5 !~ /Z/ { exit 1 }
              ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_live"; then
              cmux_ssh_auth_force_frozen=1
              break
            fi
            cmux_ssh_auth_force_attempt=$((cmux_ssh_auth_force_attempt + 1))
          done
          [ "$cmux_ssh_auth_force_frozen" = 1 ] || exit 0

          # `live` came from the confirming snapshot and contains only stable,
          # stopped identities. Do not fall back to a raw PID list if that
          # snapshot was unavailable.
          while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
            case "$cmux_pid" in ''|*[!0-9]*) continue ;; esac
            kill -KILL "$cmux_pid" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_live"
          cmux_ssh_auth_cleanup_complete=1
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
