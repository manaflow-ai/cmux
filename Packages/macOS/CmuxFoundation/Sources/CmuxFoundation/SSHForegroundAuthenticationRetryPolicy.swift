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
    /// helper sends `SIGKILL`. After `SIGTERM`, the helper waits for the
    /// PID-scoped TERM completion FIFO emitted by the authentication wrapper,
    /// then re-discovers descendants and exclusive process groups so a
    /// handler-spawned replacement remains owned. Failed snapshots never trigger
    /// an unverified kill; the EXIT path resumes stopped identities, including a
    /// PID whose identity changed after a failed stop. This keeps cleanup bounded
    /// when the runner cannot fork and avoids killing a reused PID.
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

          # SECONDS is provided by the /bin/sh used by the generated launchers
          # and avoids one fork per deadline check. The pass limits below are a
          # second bound if an older shell does not update it.
          SECONDS=0
          cmux_ssh_auth_cleanup_complete=0
          cmux_ssh_auth_cleanup_has_time() {
            [ "${SECONDS:-0}" -lt 2 ]
          }
          cmux_ssh_auth_term_wait_has_time() {
            # Keep at least one second for the force-freeze and KILL passes.
            [ "${SECONDS:-0}" -lt 1 ]
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
          cmux_ssh_auth_term_candidates="$cmux_ssh_auth_state_dir/term-candidates"
          cmux_ssh_auth_stop_candidates="$cmux_ssh_auth_state_dir/stop-candidates"
          cmux_ssh_auth_kill_candidates="$cmux_ssh_auth_state_dir/kill-candidates"
          cmux_ssh_auth_root_identity_file="$cmux_ssh_auth_state_dir/root-identity"
          cmux_ssh_auth_root_identity_candidate="$cmux_ssh_auth_state_dir/root-identity-candidate"
          cmux_ssh_auth_dynamic_groups="$cmux_ssh_auth_state_dir/dynamic-groups"
          cmux_ssh_auth_root_identity=
          cmux_ssh_auth_term_event_dir="${TMPDIR:-/tmp}/cmux-ssh-auth-term.$cmux_ssh_auth_tree_root_pid"
          cmux_ssh_auth_term_event_fifo="$cmux_ssh_auth_term_event_dir/done"
          cmux_ssh_auth_term_event_ack_fifo="$cmux_ssh_auth_term_event_dir/ack"
          cmux_ssh_auth_term_event_owned=0
          cmux_ssh_auth_term_event_received=0
          cmux_ssh_auth_caller_group_file="$cmux_ssh_auth_state_dir/caller-group"
          : > "$cmux_ssh_auth_owned" || exit 0
          : > "$cmux_ssh_auth_pending" || exit 0
          : > "$cmux_ssh_auth_dynamic_groups" || exit 0

          cmux_ssh_auth_take_snapshot() {
            /bin/ps -axo pid=,ppid=,pgid=,state=,lstart= > "$cmux_ssh_auth_snapshot" 2>/dev/null
          }

          cmux_ssh_auth_extract_tree() {
            : > "$cmux_ssh_auth_members"
            : > "$cmux_ssh_auth_groups"
            : > "$cmux_ssh_auth_root_identity_candidate"
            /usr/bin/awk \
              -v cmux_root="$cmux_ssh_auth_tree_root_pid" \
              -v cmux_root_parent="$cmux_ssh_auth_tree_root_parent" \
              -v cmux_root_identity_candidate="$cmux_ssh_auth_root_identity_candidate" \
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
                  cmux_caller_group = cmux_group[cmux_root_parent]
                  if (cmux_caller_group != "") print cmux_caller_group > cmux_caller_group_file
                }
              ' "$cmux_ssh_auth_snapshot" > "$cmux_ssh_auth_members"
            cmux_ssh_auth_extract_status=$?
            if [ "$cmux_ssh_auth_extract_status" -ne 0 ]; then return "$cmux_ssh_auth_extract_status"; fi
            cmux_ssh_auth_root_identity_candidate_value=
            if ! IFS= read -r cmux_ssh_auth_root_identity_candidate_value < "$cmux_ssh_auth_root_identity_candidate"; then
              return 1
            fi
            if [ -z "$cmux_ssh_auth_root_identity" ]; then
              cmux_ssh_auth_root_identity="$cmux_ssh_auth_root_identity_candidate_value"
              printf '%s\n' "$cmux_ssh_auth_root_identity" > "$cmux_ssh_auth_root_identity_file" || return 1
            elif [ "$cmux_ssh_auth_root_identity" != "$cmux_ssh_auth_root_identity_candidate_value" ]; then
              return 1
            fi
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
                cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                cmux_total[cmux_group]++
                if (cmux_pid in cmux_tree) cmux_inside[cmux_group]++
                if (cmux_pid == cmux_group) {
                  cmux_leader_started[cmux_group] = cmux_started
                  cmux_leader_live[cmux_group] = 1
                  cmux_leader_inside[cmux_group] = (cmux_pid in cmux_tree)
                }
              }
              END {
                for (cmux_group in cmux_total) {
                  if (cmux_group != "" && cmux_group != "0" &&
                      cmux_group != cmux_caller_group &&
                      cmux_total[cmux_group] == cmux_inside[cmux_group] &&
                      cmux_leader_live[cmux_group] &&
                      cmux_leader_inside[cmux_group]) {
                    print cmux_group, cmux_group, cmux_leader_started[cmux_group]
                  }
                }
              }
            ' "$cmux_ssh_auth_members" "$cmux_ssh_auth_snapshot" > "$cmux_ssh_auth_groups"
          }

          cmux_ssh_auth_append_pending() {
            while IFS= read -r cmux_ssh_auth_pending_line; do
              [ -n "$cmux_ssh_auth_pending_line" ] || continue
              printf '%s\n' "$cmux_ssh_auth_pending_line" >> "$cmux_ssh_auth_owned" || return 1
            done < "$cmux_ssh_auth_pending"
            : > "$cmux_ssh_auth_pending" || return 1
          }

          # A TERM handler can create a new session or process group before it
          # exits. Record only a live group leader that is still descended from
          # an identity in the original tree. The leader PID and start tuple
          # form an identity fence, so a later reuse of the numeric PGID is not
          # enough to make an unrelated group owned.
          cmux_ssh_auth_record_dynamic_groups() {
            cmux_ssh_auth_take_snapshot || return 1
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                cmux_original_identity[$2 SUBSEP $6] = 1
                next
              }
              FILENAME == ARGV[2] {
                cmux_original_group[$1] = 1
                next
              }
              FILENAME == ARGV[3] {
                cmux_caller_group = $1
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
                # Start with every current process whose PID/start identity
                # was present in the original tree, then walk current child
                # edges once. This validates parentage without trusting a PID
                # after it has been reused.
                for (cmux_pid in cmux_process) {
                  if ((cmux_pid SUBSEP cmux_started[cmux_pid]) in cmux_original_identity) {
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
                for (cmux_pid in cmux_process) {
                  cmux_group_id = cmux_group[cmux_pid]
                  cmux_started_id = cmux_started[cmux_pid]
                  if (cmux_state[cmux_pid] ~ /Z/ || cmux_pid != cmux_group_id ||
                      cmux_group_id == "" || cmux_group_id == "0" ||
                      cmux_group_id == cmux_caller_group ||
                      cmux_group_id in cmux_original_group ||
                      !(cmux_pid in cmux_lineage) ||
                      (cmux_pid SUBSEP cmux_started_id) in cmux_original_identity) continue
                  print cmux_group_id, cmux_pid, cmux_started_id
                }
              }
            ' "$cmux_ssh_auth_members" "$cmux_ssh_auth_groups" \
              "$cmux_ssh_auth_caller_group_file" \
              "$cmux_ssh_auth_snapshot" >> "$cmux_ssh_auth_dynamic_groups"
          }

          # The generated authentication wrapper writes one root PID after it
          # has sent TERM to its command, then waits for the helper ACK before
          # it waits for that command and exits. This keeps the wrapper alive
          # while the helper takes the post-TERM process-group snapshot. A
          # bounded read keeps plain fixtures and failed wrappers from
          # blocking cleanup.
          cmux_ssh_auth_wait_for_term_event() {
            [ "$cmux_ssh_auth_wait_for_term_event_enabled" = 1 ] || return 0
            if [ ! -p "$cmux_ssh_auth_term_event_fifo" ]; then return 0; fi
            exec 9<> "$cmux_ssh_auth_term_event_fifo" || return 0
            cmux_ssh_auth_term_event_writer=
            # macOS /bin/sh accepts only an integer read timeout. One-second
            # waits are bounded by the same overall cleanup deadline.
            while cmux_ssh_auth_term_wait_has_time; do
              if IFS= read -r -t 1 cmux_ssh_auth_term_event_writer <&9; then
                if [ "$cmux_ssh_auth_term_event_writer" = "$cmux_ssh_auth_tree_root_pid" ]; then
                  cmux_ssh_auth_term_event_received=1
                  break
                fi
              fi
            done
            if [ "$cmux_ssh_auth_term_event_received" != 1 ]; then
              exec 9>&-
            fi
          }

          cmux_ssh_auth_ack_term_event() {
            if [ "$cmux_ssh_auth_term_event_received" = 1 ]; then
              printf '%s\n' "$cmux_ssh_auth_tree_root_pid" >&10 2>/dev/null || true
            fi
            exec 9>&-
          }

          cmux_ssh_auth_resume_journal_directly() {
            cmux_ssh_auth_resume_path="$1"
            while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
              case "$cmux_pid" in ''|*[!0-9]*) continue ;; esac
              # This path is CONT-only. The journal records a successful STOP
              # from this helper, so recovery must not depend on another fork.
              kill -CONT "$cmux_pid" >/dev/null 2>&1 || true
            done < "$cmux_ssh_auth_resume_path"
          }

          # A successful STOP pins a process in place. If the identity check
          # fails, resume every current process with the recorded PID that is
          # either a different identity or no longer stopped. This undoes a
          # stale-PID STOP without ever sending TERM or KILL to that process.
          cmux_ssh_auth_resume_unconfirmed_stops() {
            cmux_ssh_auth_resume_path="$1"
            [ -s "$cmux_ssh_auth_resume_path" ] || return 0
            if ! cmux_ssh_auth_take_snapshot; then
              cmux_ssh_auth_resume_journal_directly "$cmux_ssh_auth_resume_path"
              return 0
            fi
            if ! cmux_ssh_auth_resume_pids=$(
                /usr/bin/awk '
                  FILENAME == ARGV[1] {
                    cmux_expected_pid[$2] = 1
                    cmux_expected[$2 SUBSEP $4 SUBSEP $6] = 1
                    next
                  }
                  NF >= 9 {
                    cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                    cmux_key = $1 SUBSEP $3 SUBSEP cmux_started
                    if (($1 in cmux_expected_pid) &&
                        (!(cmux_key in cmux_expected) || $4 !~ /T/) &&
                        $4 !~ /Z/) print $1
                  }
                ' "$cmux_ssh_auth_resume_path" "$cmux_ssh_auth_snapshot"
              ); then
              cmux_ssh_auth_resume_journal_directly "$cmux_ssh_auth_resume_path"
              return 0
            fi
            for cmux_ssh_auth_resume_pid in $cmux_ssh_auth_resume_pids; do
              case "$cmux_ssh_auth_resume_pid" in ''|*[!0-9]*) continue ;; esac
              kill -CONT "$cmux_ssh_auth_resume_pid" >/dev/null 2>&1 || true
            done
          }

          # Re-read the process table once immediately before each signal
          # batch. A matching PID/PGID/start tuple is the only record emitted.
          # STOP confirmation then pins that identity until TERM or KILL, so a
          # PID reuse cannot turn a stale row into a destructive signal.
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
            if ! cmux_ssh_auth_take_snapshot; then
              cmux_ssh_auth_resume_journal_directly "$cmux_ssh_auth_resume_path"
              return 0
            fi
            if ! cmux_ssh_auth_resume_pids=$(
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
              ); then
              cmux_ssh_auth_resume_journal_directly "$cmux_ssh_auth_resume_path"
              return 0
            fi
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
            if [ "$cmux_ssh_auth_term_event_owned" = 1 ]; then
              /bin/rm -f "$cmux_ssh_auth_term_event_fifo" "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null || true
            fi
            # Unlink the FIFOs before closing the helper's descriptors. The
            # open ACK descriptor keeps a wrapper-side read from blocking when
            # the event wait times out; unlinking first also wakes a reader
            # that races with cleanup.
            exec 9>&- 2>/dev/null || true
            exec 10>&- 2>/dev/null || true
            /bin/rm -f "$cmux_ssh_auth_snapshot" "$cmux_ssh_auth_members" \
              "$cmux_ssh_auth_pending" "$cmux_ssh_auth_owned" "$cmux_ssh_auth_groups" \
              "$cmux_ssh_auth_live" "$cmux_ssh_auth_term" \
              "$cmux_ssh_auth_term_candidates" "$cmux_ssh_auth_stop_candidates" \
              "$cmux_ssh_auth_kill_candidates" "$cmux_ssh_auth_caller_group_file" \
              "$cmux_ssh_auth_root_identity_file" "$cmux_ssh_auth_root_identity_candidate" \
              "$cmux_ssh_auth_dynamic_groups" \
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
          # The authentication wrapper derives this same path from its parent
          # PID. A pre-existing path is never removed or reused, so a stale
          # process cannot receive an event from this cleanup attempt.
          if [ "$cmux_ssh_auth_wait_for_term_event_enabled" = 1 ] && \
            /bin/mkdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null && \
            /usr/bin/mkfifo "$cmux_ssh_auth_term_event_fifo" 2>/dev/null && \
            /usr/bin/mkfifo "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null && \
            exec 9<> "$cmux_ssh_auth_term_event_fifo" 2>/dev/null && \
            exec 10<> "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null; then
            cmux_ssh_auth_term_event_owned=1
          else
            exec 9>&- 2>/dev/null || true
            exec 10>&- 2>/dev/null || true
            /bin/rm -f "$cmux_ssh_auth_term_event_fifo" "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null || true
            /bin/rmdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null || true
            cmux_ssh_auth_term_event_fifo=
            cmux_ssh_auth_term_event_ack_fifo=
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
            done < "$cmux_ssh_auth_stop_candidates"
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
          while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
            case "$cmux_pid" in ''|*[!0-9]*) continue ;; esac
            kill -TERM "$cmux_pid" >/dev/null 2>&1 || true
            kill -CONT "$cmux_pid" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_term"
          # The wrapper sends its event immediately after forwarding TERM and
          # waits for our ACK. Snapshot before ACK so a replacement is still
          # attached to the live wrapper even when its direct parent exits.
          cmux_ssh_auth_wait_for_term_event
          cmux_ssh_auth_record_dynamic_groups || true
          # Refresh once more before releasing the wrapper. The leader
          # identity journal remains valid after reparenting.
          cmux_ssh_auth_record_dynamic_groups || true
          cmux_ssh_auth_ack_term_event

          # Rebuild ownership from exact identities, exclusive groups, and
          # descendants. This catches a replacement that outlives its parent.
          cmux_ssh_auth_extract_owned() {
            : > "$cmux_ssh_auth_live"
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                cmux_owned_identity[$2 SUBSEP $4 SUBSEP $6] = 1
                next
              }
              FILENAME == ARGV[2] {
                cmux_exclusive_leader_pid[$1] = $2
                cmux_exclusive_leader_started[$1] = $3
                next
              }
              FILENAME == ARGV[3] {
                cmux_dynamic_leader[$1] = $2 SUBSEP $3
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
                if ((cmux_pid SUBSEP $3 SUBSEP cmux_started[cmux_pid]) in cmux_owned_identity) {
                  cmux_seen[cmux_pid] = 1
                  cmux_queue[++cmux_queue_tail] = cmux_pid
                  cmux_depth[cmux_pid] = 0
                }
              }
              END {
                # A process group ID is reusable. Accept the group-wide
                # ownership path only while the original leader has the
                # exact PID/start identity captured before TERM.
                for (cmux_group_id in cmux_exclusive_leader_pid) {
                  cmux_leader_pid = cmux_exclusive_leader_pid[cmux_group_id]
                  cmux_leader_started = cmux_exclusive_leader_started[cmux_group_id]
                  if (cmux_leader_pid in cmux_process &&
                      cmux_group[cmux_leader_pid] == cmux_group_id &&
                      cmux_started[cmux_leader_pid] == cmux_leader_started &&
                      cmux_state[cmux_leader_pid] !~ /Z/) {
                    cmux_valid_exclusive_group[cmux_group_id] = 1
                  }
                }
                for (cmux_pid in cmux_process) {
                  if (cmux_valid_exclusive_group[cmux_group[cmux_pid]] &&
                      !(cmux_pid in cmux_seen) && cmux_state[cmux_pid] !~ /Z/) {
                    cmux_seen[cmux_pid] = 1
                    cmux_queue[++cmux_queue_tail] = cmux_pid
                    cmux_depth[cmux_pid] = 0
                  }
                  if (cmux_pid == cmux_group[cmux_pid] &&
                      cmux_dynamic_leader[cmux_group[cmux_pid]] ==
                        (cmux_pid SUBSEP cmux_started[cmux_pid])) {
                    cmux_dynamic_group[cmux_group[cmux_pid]] = 1
                  }
                }
                # A dynamic group is valid only while its recorded leader
                # still has the exact PID/start identity. Once validated,
                # every current member of that group is owned, including
                # siblings that are not descendants of the leader.
                for (cmux_pid in cmux_process) {
                  if (cmux_group[cmux_pid] in cmux_dynamic_group &&
                      !(cmux_pid in cmux_seen) && cmux_state[cmux_pid] !~ /Z/) {
                    cmux_seen[cmux_pid] = 1
                    cmux_queue[++cmux_queue_tail] = cmux_pid
                    cmux_depth[cmux_pid] = 0
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
            ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_groups" "$cmux_ssh_auth_dynamic_groups" \
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
            while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
              case "$cmux_pid:$cmux_parent:$cmux_group:$cmux_started" in
                *[!0-9A-Za-z_:]*|:*|*:) continue ;;
              esac
              if kill -STOP "$cmux_pid" >/dev/null 2>&1; then
                printf '%s %s %s %s %s %s\n' \
                  "$cmux_depth" "$cmux_pid" "$cmux_parent" "$cmux_group" "$cmux_state" "$cmux_started" \
                  >> "$cmux_ssh_auth_pending" || exit 0
              fi
            done < "$cmux_ssh_auth_stop_candidates"
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
          while IFS=' ' read -r cmux_depth cmux_pid cmux_parent cmux_group cmux_state cmux_started; do
            case "$cmux_pid" in ''|*[!0-9]*) continue ;; esac
            if ! kill -KILL "$cmux_pid" >/dev/null 2>&1; then
              # A process can exit between the confirming snapshot and this
              # builtin call. Retry once, then leave the EXIT rollback armed
              # if the PID still refuses the signal.
              if ! kill -KILL "$cmux_pid" >/dev/null 2>&1; then
                cmux_ssh_auth_kill_failed=1
              fi
            fi
          done < "$cmux_ssh_auth_kill_candidates"
          if [ "$cmux_ssh_auth_kill_failed" = 0 ]; then
            cmux_ssh_auth_cleanup_complete=1
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
            // The classifier is the process-tree root passed to the cleanup
            // helper. Use its own PID for the per-attempt event path. Nested
            // commands keep their own PID and cannot publish this event.
            "CMUX_SSH_AUTH_ROOT_PID=\"$$\"; export CMUX_SSH_AUTH_ROOT_PID",
            "cmux_ssh_auth_term_event_fifo=\"${TMPDIR:-/tmp}/cmux-ssh-auth-term.${CMUX_SSH_AUTH_ROOT_PID}/done\"",
            "cmux_ssh_auth_term_event_ack_fifo=\"${TMPDIR:-/tmp}/cmux-ssh-auth-term.${CMUX_SSH_AUTH_ROOT_PID}/ack\"",
            // Notify the cleanup helper after forwarding TERM, then wait for
            // its ACK. The helper uses this pause to snapshot replacements
            // before the command handler can orphan them.
            "cmux_ssh_auth_signal_completion() { if [ -p \"$cmux_ssh_auth_term_event_fifo\" ]; then if exec 8<> \"$cmux_ssh_auth_term_event_fifo\" 2>/dev/null; then printf '%s\\n' \"$$\" >&8 2>/dev/null || true; exec 8>&-; fi; if [ -p \"$cmux_ssh_auth_term_event_ack_fifo\" ] && exec 8<> \"$cmux_ssh_auth_term_event_ack_fifo\" 2>/dev/null; then cmux_ssh_auth_completion_ack=; IFS= read -r -t 2 cmux_ssh_auth_completion_ack <&8 || true; exec 8>&-; fi; fi; }",
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
            "    cmux_ssh_auth_signal_completion",
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
