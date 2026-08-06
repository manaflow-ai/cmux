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
    /// the classifier, nested PTY, and SSH process. The helper snapshots that tree,
    /// freezes every discovered member, and repeats until no runnable descendant
    /// remains. Isolated PTY process groups receive a graceful TERM while shared
    /// wrapper processes stay frozen, preventing a shared-group handler from forking
    /// outside the owned tree. A final snapshot freezes TERM-handler replacements
    /// before group KILL, while shared processes are force-killed only after their
    /// PID, parent, process-group, and start-time identities are revalidated.
    /// The caller supplies the authentication root's known wrapper PID so root
    /// validation is not inferred from a potentially reused candidate PID.
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

          umask 077
          cmux_ssh_auth_state_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmux-ssh-auth-tree.XXXXXX") || exit 0
          cmux_ssh_auth_snapshot="$cmux_ssh_auth_state_dir/snapshot"
          cmux_ssh_auth_members="$cmux_ssh_auth_state_dir/members"
          cmux_ssh_auth_frozen="$cmux_ssh_auth_state_dir/frozen"
          cmux_ssh_auth_owned="$cmux_ssh_auth_state_dir/owned"
          cmux_ssh_auth_groups="$cmux_ssh_auth_state_dir/groups"
          cmux_ssh_auth_force_groups="$cmux_ssh_auth_state_dir/force-groups"
          cmux_ssh_auth_shared="$cmux_ssh_auth_state_dir/shared"
          cmux_ssh_auth_live="$cmux_ssh_auth_state_dir/live"
          cmux_ssh_auth_started_at=$(/bin/date +%s 2>/dev/null) || exit 0
          case "$cmux_ssh_auth_started_at" in ''|*[!0-9]*) exit 0 ;; esac
          cmux_ssh_auth_deadline=$((cmux_ssh_auth_started_at + 2))
          for cmux_ssh_auth_file in \
            "$cmux_ssh_auth_frozen" "$cmux_ssh_auth_owned" "$cmux_ssh_auth_groups" \
            "$cmux_ssh_auth_force_groups" "$cmux_ssh_auth_shared"; do
            : > "$cmux_ssh_auth_file" || exit 0
          done

          cmux_ssh_auth_has_time() {
            cmux_ssh_auth_now=$(/bin/date +%s 2>/dev/null) || return 1
            case "$cmux_ssh_auth_now" in ''|*[!0-9]*) return 1 ;; esac
            [ "$cmux_ssh_auth_now" -lt "$cmux_ssh_auth_deadline" ]
          }

          cmux_ssh_auth_take_snapshot() {
            /bin/ps -axo pid=,ppid=,pgid=,state=,lstart= > "$cmux_ssh_auth_snapshot" 2>/dev/null
          }

          cmux_ssh_auth_extract_tree() {
            /usr/bin/awk \
              -v cmux_root="$cmux_ssh_auth_tree_root_pid" \
              -v cmux_root_parent="$cmux_ssh_auth_tree_root_parent" '
                NF >= 9 {
                  cmux_pid = $1
                  cmux_parent[cmux_pid] = $2
                  cmux_group[cmux_pid] = $3
                  cmux_state[cmux_pid] = $4
                  cmux_started[cmux_pid] = $5 "_" $6 "_" $7 "_" $8 "_" $9
                  cmux_process[cmux_pid] = 1
                }
                END {
                  if (!(cmux_root in cmux_process) ||
                      cmux_parent[cmux_root] != cmux_root_parent ||
                      cmux_state[cmux_root] ~ /Z/) {
                    exit
                  }
                  cmux_depth[cmux_root] = 0
                  cmux_changed = 1
                  while (cmux_changed) {
                    cmux_changed = 0
                    for (cmux_candidate in cmux_process) {
                      if (cmux_candidate in cmux_depth || cmux_state[cmux_candidate] ~ /Z/) {
                        continue
                      }
                      if (cmux_parent[cmux_candidate] in cmux_depth) {
                        cmux_depth[cmux_candidate] = cmux_depth[cmux_parent[cmux_candidate]] + 1
                        cmux_changed = 1
                      }
                    }
                  }
                  for (cmux_candidate in cmux_depth) {
                    print cmux_depth[cmux_candidate], cmux_candidate,
                      cmux_parent[cmux_candidate], cmux_group[cmux_candidate],
                      cmux_started[cmux_candidate], cmux_state[cmux_candidate]
                  }
                }
              ' "$cmux_ssh_auth_snapshot" | /usr/bin/sort -n -k1,1 -k2,2n > "$cmux_ssh_auth_members"
          }

          cmux_ssh_auth_extract_group_members() {
            /usr/bin/awk '
              FILENAME == ARGV[1] { cmux_group[$1] = 1; next }
              NF >= 9 && ($3 in cmux_group) && $4 !~ /Z/ {
                cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                print 0, $1, $2, $3, cmux_started, $4
              }
            ' "$cmux_ssh_auth_groups" "$cmux_ssh_auth_snapshot" | \
              /usr/bin/sort -n -k2,2n > "$cmux_ssh_auth_members"
          }

          cmux_ssh_auth_extract_identity_matches() {
            cmux_ssh_auth_identity_source="$1"
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                cmux_identity[$2 SUBSEP $3 SUBSEP $4 SUBSEP $5] = 1
                next
              }
              NF >= 9 {
                cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                if (($1 SUBSEP $2 SUBSEP $3 SUBSEP cmux_started) in cmux_identity && $4 !~ /Z/) {
                  print 0, $1, $2, $3, cmux_started, $4
                }
              }
            ' "$cmux_ssh_auth_identity_source" "$cmux_ssh_auth_snapshot" | \
              /usr/bin/sort -n -k2,2n > "$cmux_ssh_auth_live"
          }

          cmux_ssh_auth_freeze_file() {
            cmux_ssh_auth_freeze_source="$1"
            : > "$cmux_ssh_auth_frozen" || return 1
            while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_started cmux_state; do
              case "$cmux_pid:$cmux_parent:$cmux_group" in *[!0-9:]*) continue ;; esac
              if kill -STOP "$cmux_pid" >/dev/null 2>&1; then
                printf '%s %s %s %s %s %s\n' \
                  "$cmux_depth" "$cmux_pid" "$cmux_parent" "$cmux_group" "$cmux_started" "$cmux_state" \
                  >> "$cmux_ssh_auth_frozen" || return 1
              fi
            done < "$cmux_ssh_auth_freeze_source"
          }

          cmux_ssh_auth_records_are_frozen() {
            cmux_ssh_auth_observed="$1"
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                cmux_frozen[$2 SUBSEP $3 SUBSEP $4 SUBSEP $5] = 1
                next
              }
              $6 !~ /T/ || !(($2 SUBSEP $3 SUBSEP $4 SUBSEP $5) in cmux_frozen) { exit 1 }
            ' "$cmux_ssh_auth_frozen" "$cmux_ssh_auth_observed"
          }

          cmux_ssh_auth_resume_file() {
            cmux_ssh_auth_resume_source="$1"
            if [ ! -s "$cmux_ssh_auth_resume_source" ]; then return; fi
            cmux_ssh_auth_take_snapshot || return
            cmux_ssh_auth_extract_identity_matches "$cmux_ssh_auth_resume_source" || return
            while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_started cmux_state; do
              case "$cmux_pid" in ''|*[!0-9]*) continue ;; esac
              kill -CONT "$cmux_pid" >/dev/null 2>&1 || true
            done < "$cmux_ssh_auth_live"
          }

          cmux_ssh_auth_cleanup() {
            trap - EXIT HUP INT TERM
            cmux_ssh_auth_resume_file "$cmux_ssh_auth_frozen"
            cmux_ssh_auth_resume_file "$cmux_ssh_auth_owned"
            /bin/rm -f "$cmux_ssh_auth_snapshot" "$cmux_ssh_auth_members" \
              "$cmux_ssh_auth_frozen" "$cmux_ssh_auth_owned" "$cmux_ssh_auth_groups" \
              "$cmux_ssh_auth_force_groups" "$cmux_ssh_auth_shared" "$cmux_ssh_auth_live" \
              2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_state_dir" 2>/dev/null || true
          }
          trap 'cmux_ssh_auth_cleanup' EXIT
          trap 'cmux_ssh_auth_cleanup; exit 0' HUP INT TERM

          cmux_ssh_auth_parent_group=$(/bin/ps -o pgid= -p "$cmux_ssh_auth_tree_root_parent" 2>/dev/null | /usr/bin/tr -d '[:space:]')
          case "$cmux_ssh_auth_parent_group" in ''|0|*[!0-9]*) cmux_ssh_auth_parent_group= ;; esac

          cmux_ssh_auth_freeze_attempt=0
          cmux_ssh_auth_tree_frozen=
          while [ "$cmux_ssh_auth_freeze_attempt" -lt 4 ]; do
            if [ "$cmux_ssh_auth_freeze_attempt" -gt 0 ] && ! cmux_ssh_auth_has_time; then break; fi
            cmux_ssh_auth_take_snapshot || exit 0
            cmux_ssh_auth_extract_tree || exit 0
            if [ ! -s "$cmux_ssh_auth_members" ]; then exit 0; fi
            cmux_ssh_auth_freeze_file "$cmux_ssh_auth_members" || exit 0
            cmux_ssh_auth_take_snapshot || exit 0
            cmux_ssh_auth_extract_tree || exit 0
            if [ ! -s "$cmux_ssh_auth_members" ]; then exit 0; fi
            if cmux_ssh_auth_records_are_frozen "$cmux_ssh_auth_members"; then
              /bin/cp "$cmux_ssh_auth_members" "$cmux_ssh_auth_owned" || exit 0
              /bin/cp "$cmux_ssh_auth_members" "$cmux_ssh_auth_frozen" || exit 0
              cmux_ssh_auth_tree_frozen=1
              break
            fi
            cmux_ssh_auth_freeze_attempt=$((cmux_ssh_auth_freeze_attempt + 1))
          done
          if [ -z "$cmux_ssh_auth_tree_frozen" ]; then exit 0; fi

          case "$cmux_ssh_auth_parent_group" in
            '') /bin/cp "$cmux_ssh_auth_owned" "$cmux_ssh_auth_shared" || exit 0 ;;
            *)
              /usr/bin/awk -v cmux_parent_group="$cmux_ssh_auth_parent_group" \
                '$4 != cmux_parent_group && $4 != 0 { print $4 }' "$cmux_ssh_auth_owned" | \
                /usr/bin/sort -un > "$cmux_ssh_auth_groups" || exit 0
              /usr/bin/awk -v cmux_parent_group="$cmux_ssh_auth_parent_group" \
                '$4 == cmux_parent_group { print }' "$cmux_ssh_auth_owned" > "$cmux_ssh_auth_shared" || exit 0
              ;;
          esac

          cmux_ssh_auth_signal_groups() {
            cmux_ssh_auth_group_signal="$1"
            cmux_ssh_auth_group_source="$2"
            while IFS= read -r cmux_group; do
              case "$cmux_group" in ''|0|*[!0-9]*) continue ;; esac
              /bin/kill -"$cmux_ssh_auth_group_signal" -- "-$cmux_group" >/dev/null 2>&1 || true
            done < "$cmux_ssh_auth_group_source"
          }

          cmux_ssh_auth_signal_records() {
            cmux_ssh_auth_record_signal="$1"
            cmux_ssh_auth_record_source="$2"
            /usr/bin/sort -nr -k1,1 -k2,2nr "$cmux_ssh_auth_record_source" | \
              while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_started cmux_state; do
                case "$cmux_pid" in ''|*[!0-9]*) continue ;; esac
                kill -"$cmux_ssh_auth_record_signal" "$cmux_pid" >/dev/null 2>&1 || true
              done
          }

          # Only the nested PTY groups receive TERM. Shared wrappers remain
          # stopped so their handlers cannot fork processes into the caller's group.
          if [ -s "$cmux_ssh_auth_groups" ]; then
            cmux_ssh_auth_signal_groups TERM "$cmux_ssh_auth_groups"
            cmux_ssh_auth_signal_groups CONT "$cmux_ssh_auth_groups"
            if cmux_ssh_auth_has_time; then /bin/sleep 0.2; fi

            cmux_ssh_auth_group_freeze_attempt=0
            cmux_ssh_auth_groups_frozen=
            while [ "$cmux_ssh_auth_group_freeze_attempt" -lt 4 ]; do
              if [ "$cmux_ssh_auth_group_freeze_attempt" -gt 0 ] && ! cmux_ssh_auth_has_time; then break; fi
              cmux_ssh_auth_take_snapshot || break
              cmux_ssh_auth_extract_group_members || break
              if [ ! -s "$cmux_ssh_auth_members" ]; then
                : > "$cmux_ssh_auth_frozen"
                cmux_ssh_auth_groups_frozen=1
                break
              fi
              cmux_ssh_auth_freeze_file "$cmux_ssh_auth_members" || break
              cmux_ssh_auth_take_snapshot || break
              cmux_ssh_auth_extract_group_members || break
              if [ ! -s "$cmux_ssh_auth_members" ]; then
                : > "$cmux_ssh_auth_frozen"
                cmux_ssh_auth_groups_frozen=1
                break
              fi
              if cmux_ssh_auth_records_are_frozen "$cmux_ssh_auth_members"; then
                /bin/cp "$cmux_ssh_auth_members" "$cmux_ssh_auth_frozen" || break
                cmux_ssh_auth_groups_frozen=1
                break
              fi
              cmux_ssh_auth_group_freeze_attempt=$((cmux_ssh_auth_group_freeze_attempt + 1))
            done

            # Frozen live members pin each process-group identity until KILL.
            if [ -n "$cmux_ssh_auth_groups_frozen" ] && [ -s "$cmux_ssh_auth_frozen" ]; then
              /usr/bin/awk '$4 != 0 { print $4 }' "$cmux_ssh_auth_frozen" | \
                /usr/bin/sort -un > "$cmux_ssh_auth_force_groups" || exit 0
              cmux_ssh_auth_signal_groups KILL "$cmux_ssh_auth_force_groups"
            elif [ -z "$cmux_ssh_auth_groups_frozen" ] && [ -s "$cmux_ssh_auth_frozen" ]; then
              cmux_ssh_auth_take_snapshot || exit 0
              cmux_ssh_auth_extract_identity_matches "$cmux_ssh_auth_frozen" || exit 0
              /usr/bin/awk '$6 ~ /T/ && $4 != 0 { print $4 }' "$cmux_ssh_auth_live" | \
                /usr/bin/sort -un > "$cmux_ssh_auth_force_groups" || exit 0
              cmux_ssh_auth_signal_groups KILL "$cmux_ssh_auth_force_groups"
            fi
          fi

          # Shared wrapper identities never ran after the initial freeze. Match
          # them against a fresh process snapshot immediately before force-kill.
          if [ -s "$cmux_ssh_auth_shared" ]; then
            cmux_ssh_auth_take_snapshot || exit 0
            cmux_ssh_auth_extract_identity_matches "$cmux_ssh_auth_shared" || exit 0
            cmux_ssh_auth_freeze_file "$cmux_ssh_auth_live" || exit 0
            cmux_ssh_auth_take_snapshot || exit 0
            cmux_ssh_auth_extract_identity_matches "$cmux_ssh_auth_frozen" || exit 0
            cmux_ssh_auth_signal_records KILL "$cmux_ssh_auth_live"
          fi
          cmux_ssh_auth_cleanup
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
