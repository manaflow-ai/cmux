extension SSHForegroundAuthenticationRetryPolicy {
    func ownedProcessGroupTerminationShellFunctions() -> String {
        #"""
        cmux_ssh_auth_now_millis() {
          /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
        }

        cmux_ssh_auth_deadline_allows_work() {
          cmux_ssh_auth_now="$(cmux_ssh_auth_now_millis)" || return 1
          case "$cmux_ssh_auth_now:$cmux_ssh_auth_deadline_millis" in
            *[!0-9:]*|:*|*:) return 1 ;;
          esac
          [ "$cmux_ssh_auth_now" -lt "$cmux_ssh_auth_deadline_millis" ]
        }

        cmux_ssh_auth_deadline_allows_signal() {
          if [ "${cmux_ssh_auth_signal_deadline:-}" != \
            "$cmux_ssh_auth_deadline_millis" ]; then
            cmux_ssh_auth_signal_deadline="$cmux_ssh_auth_deadline_millis"
            cmux_ssh_auth_signal_budget=0
          fi
          case "${cmux_ssh_auth_signal_budget:-}" in
            ''|*[!0-9]*) cmux_ssh_auth_signal_budget=0 ;;
          esac
          if [ "$cmux_ssh_auth_signal_budget" -le 0 ]; then
            cmux_ssh_auth_deadline_allows_work || return 1
            # Each unchecked operation is one nonblocking kill(2) plus a
            # bounded file append. Refresh the wall clock every 64 signals
            # without paying one process launch per PID.
            cmux_ssh_auth_signal_budget=63
          else
            cmux_ssh_auth_signal_budget=$((cmux_ssh_auth_signal_budget - 1))
          fi
          return 0
        }

        cmux_ssh_auth_reset_stop_budget() {
          # Rollback must attempt CONT for every write-ahead STOP record even
          # after the termination deadline. Cap each transaction's durable
          # identities so draining either journal remains finite without
          # sharing that deadline.
          cmux_ssh_auth_stop_budget=1024
        }

        cmux_ssh_auth_stop_budget_allows_signal() {
          case "${cmux_ssh_auth_stop_budget:-}" in
            ''|*[!0-9]*) return 1 ;;
          esac
          if [ "$cmux_ssh_auth_stop_budget" -le 0 ]; then return 1; fi
          cmux_ssh_auth_stop_budget=$((cmux_ssh_auth_stop_budget - 1))
          return 0
        }

        cmux_ssh_auth_take_process_snapshot_until() {
          cmux_ssh_auth_snapshot_output="$1"
          cmux_ssh_auth_snapshot_deadline="$2"
          cmux_ssh_auth_snapshot_now="$(cmux_ssh_auth_now_millis)" || return 1
          case "$cmux_ssh_auth_snapshot_now:$cmux_ssh_auth_snapshot_deadline" in
            *[!0-9:]*|:*|*:) return 1 ;;
          esac
          cmux_ssh_auth_snapshot_remaining=$((
            cmux_ssh_auth_snapshot_deadline - cmux_ssh_auth_snapshot_now
          ))
          if [ "$cmux_ssh_auth_snapshot_remaining" -le 0 ]; then return 1; fi

          /usr/bin/perl -MTime::HiRes=alarm -e '
            $cmux_timeout_millis = shift;
            $cmux_timeout = $cmux_timeout_millis / 1000;
            $cmux_pid = fork();
            exit 1 if !defined $cmux_pid;
            if ($cmux_pid == 0) {
              exec @ARGV;
              exit 127;
            }
            $cmux_timed_out = 0;
            local $SIG{ALRM} = sub {
              $cmux_timed_out = 1;
              kill 9, $cmux_pid;
            };
            alarm $cmux_timeout;
            do {
              $cmux_waited = waitpid($cmux_pid, 0);
            } while ($cmux_waited == -1 && $!{EINTR});
            $cmux_status = $?;
            alarm 0;
            if ($cmux_waited == -1) {
              kill 9, $cmux_pid;
              waitpid($cmux_pid, 0);
              exit 1;
            }
            exit 124 if $cmux_timed_out;
            exit(128 + ($cmux_status & 127)) if $cmux_status & 127;
            exit($cmux_status >> 8);
          ' "$cmux_ssh_auth_snapshot_remaining" \
            /usr/bin/env LC_ALL=C LANG=C /bin/ps -axo pid=,ppid=,pgid=,state=,lstart= \
            > "$cmux_ssh_auth_snapshot_output" 2>/dev/null
        }

        cmux_ssh_auth_take_process_snapshot() {
          cmux_ssh_auth_take_process_snapshot_until \
            "$1" "$cmux_ssh_auth_deadline_millis"
        }

        cmux_ssh_auth_expand_owned_processes() {
          cmux_ssh_auth_expand_snapshot="${1:-$cmux_ssh_auth_process_snapshot}"
          /usr/bin/awk -v cmux_root_group="$cmux_ssh_auth_owned_group" '
            FILENAME == ARGV[1] {
              cmux_previous[$1 SUBSEP $3 SUBSEP $4] = 1
              next
            }
            NF >= 9 && $4 !~ /Z/ {
              cmux_pid = $1
              cmux_parent[cmux_pid] = $2
              cmux_group[cmux_pid] = $3
              cmux_state[cmux_pid] = $4
              cmux_started[cmux_pid] = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_next_sibling[cmux_pid] = cmux_first_child[$2]
              cmux_first_child[$2] = cmux_pid
              if ($3 == cmux_root_group ||
                  (($1 SUBSEP $3 SUBSEP cmux_started[cmux_pid]) in cmux_previous)) {
                cmux_owned[cmux_pid] = 1
                cmux_queue[++cmux_queue_tail] = cmux_pid
              }
            }
            END {
              cmux_queue_head = 1
              while (cmux_queue_head <= cmux_queue_tail) {
                cmux_parent_pid = cmux_queue[cmux_queue_head++]
                cmux_child_pid = cmux_first_child[cmux_parent_pid]
                while (cmux_child_pid != "") {
                  if (!(cmux_child_pid in cmux_owned)) {
                    cmux_owned[cmux_child_pid] = 1
                    cmux_queue[++cmux_queue_tail] = cmux_child_pid
                  }
                  cmux_child_pid = cmux_next_sibling[cmux_child_pid]
                }
              }
              for (cmux_pid in cmux_owned) {
                print cmux_pid, cmux_parent[cmux_pid], cmux_group[cmux_pid],
                  cmux_started[cmux_pid], cmux_state[cmux_pid]
              }
            }
          ' "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_expand_snapshot" \
            > "$cmux_ssh_auth_next_owned_processes" || return 1
          /usr/bin/sort -n -k1,1 -o "$cmux_ssh_auth_next_owned_processes" \
            "$cmux_ssh_auth_next_owned_processes" || return 1
          /bin/mv -f -- "$cmux_ssh_auth_next_owned_processes" "$cmux_ssh_auth_owned_processes"
        }

        cmux_ssh_auth_order_children_first() {
          /usr/bin/awk '
            {
              cmux_record[$1] = $0
              cmux_parent[$1] = $2
              # Retain the last record for a PID, but link that PID only once.
              if (!($1 in cmux_seen_pid)) {
                cmux_seen_pid[$1] = 1
                cmux_pid_order[++cmux_pid_count] = $1
              }
            }
            END {
              for (cmux_index = 1; cmux_index <= cmux_pid_count; cmux_index++) {
                cmux_pid = cmux_pid_order[cmux_index]
                cmux_next_sibling[cmux_pid] = cmux_first_child[cmux_parent[cmux_pid]]
                cmux_first_child[cmux_parent[cmux_pid]] = cmux_pid
              }
              for (cmux_index = 1; cmux_index <= cmux_pid_count; cmux_index++) {
                cmux_pid = cmux_pid_order[cmux_index]
                if (!(cmux_parent[cmux_pid] in cmux_record)) {
                  cmux_depth[cmux_pid] = 0
                  cmux_queue[++cmux_queue_tail] = cmux_pid
                }
              }
              cmux_queue_head = 1
              while (cmux_queue_head <= cmux_queue_tail) {
                cmux_parent_pid = cmux_queue[cmux_queue_head++]
                cmux_child_pid = cmux_first_child[cmux_parent_pid]
                while (cmux_child_pid != "") {
                  if (!(cmux_child_pid in cmux_visited)) {
                    cmux_visited[cmux_child_pid] = 1
                    cmux_depth[cmux_child_pid] = cmux_depth[cmux_parent_pid] + 1
                    cmux_queue[++cmux_queue_tail] = cmux_child_pid
                  }
                  cmux_child_pid = cmux_next_sibling[cmux_child_pid]
                }
              }
              for (cmux_index = 1; cmux_index <= cmux_pid_count; cmux_index++) {
                cmux_pid = cmux_pid_order[cmux_index]
                print cmux_depth[cmux_pid] + 0, cmux_record[cmux_pid]
              }
            }
          ' "$1" > "$2" || return 1
          /usr/bin/sort -k1,1nr -k2,2nr -o "$2" "$2"
        }

        cmux_ssh_auth_select_exclusive_groups() {
          cmux_ssh_auth_group_snapshot="${1:-$cmux_ssh_auth_process_snapshot}"
          /usr/bin/awk -v cmux_caller_group="$cmux_ssh_auth_caller_group" '
            FILENAME == ARGV[1] && NF >= 5 {
              cmux_owned[$1 SUBSEP $3 SUBSEP $4] = 1
              if ($3 != 0 && $3 != cmux_caller_group) cmux_candidate[$3] = 1
              next
            }
            FILENAME == ARGV[2] && NF >= 9 && $4 !~ /Z/ {
              cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
              if ($3 in cmux_candidate) {
                cmux_seen[$3] = 1
                if (!(($1 SUBSEP $3 SUBSEP cmux_started) in cmux_owned)) {
                  cmux_mixed[$3] = 1
                }
              }
            }
            END {
              for (cmux_group in cmux_candidate) {
                if (cmux_group in cmux_seen && !(cmux_group in cmux_mixed)) print cmux_group
              }
            }
          ' "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_group_snapshot" \
            > "$cmux_ssh_auth_next_owned_groups" || return 1
          /usr/bin/sort -un -o "$cmux_ssh_auth_next_owned_groups" \
            "$cmux_ssh_auth_next_owned_groups" || return 1
          /bin/mv -f -- "$cmux_ssh_auth_next_owned_groups" \
            "$cmux_ssh_auth_owned_groups"
        }

        cmux_ssh_auth_filter_current_processes() {
          cmux_ssh_auth_filter_snapshot="$1"
          cmux_ssh_auth_filter_candidates="$2"
          cmux_ssh_auth_filter_output="$3"
          cmux_ssh_auth_filter_require_stopped="$4"
          /usr/bin/awk -v cmux_require_stopped="$cmux_ssh_auth_filter_require_stopped" '
            FILENAME == ARGV[1] && NF >= 9 && $4 !~ /Z/ {
              cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_current[$1 SUBSEP $3 SUBSEP cmux_started] = $4
              next
            }
            FILENAME == ARGV[2] && NF >= 5 {
              cmux_key = $1 SUBSEP $3 SUBSEP $4
              if (cmux_key in cmux_current &&
                  (!cmux_require_stopped || cmux_current[cmux_key] ~ /T/)) print
            }
          ' "$cmux_ssh_auth_filter_snapshot" "$cmux_ssh_auth_filter_candidates" \
            > "$cmux_ssh_auth_filter_output"
        }

        cmux_ssh_auth_freeze_owned_processes() {
          cmux_ssh_auth_deadline_allows_work || return 1
          case "${cmux_ssh_auth_stop_budget:-}" in
            ''|*[!0-9]*) cmux_ssh_auth_reset_stop_budget ;;
          esac
          cmux_ssh_auth_select_exclusive_groups || return 1
          : > "$cmux_ssh_auth_signaled_groups" || return 1
          : > "$cmux_ssh_auth_frozen_processes" || return 1
          # A verified exclusive group can be KILLed atomically without STOP
          # recovery. Shared groups use exact process identities, capped so
          # rollback is always finite.
          /usr/bin/awk '
            FILENAME == ARGV[1] { cmux_exclusive[$1] = 1; next }
            !($3 in cmux_exclusive) { print }
          ' "$cmux_ssh_auth_owned_groups" "$cmux_ssh_auth_owned_processes" \
            > "$cmux_ssh_auth_individual_processes" || return 1
          cmux_ssh_auth_filter_current_processes "$cmux_ssh_auth_process_snapshot" \
            "$cmux_ssh_auth_individual_processes" \
            "$cmux_ssh_auth_next_owned_processes" 0 || return 1
          cmux_ssh_auth_order_children_first "$cmux_ssh_auth_next_owned_processes" \
            "$cmux_ssh_auth_ordered_processes" || return 1
          while read -r cmux_ssh_auth_depth cmux_ssh_auth_pid cmux_ssh_auth_parent cmux_ssh_auth_group \
            cmux_ssh_auth_started cmux_ssh_auth_state; do
            cmux_ssh_auth_deadline_allows_signal || return 1
            case "$cmux_ssh_auth_pid:$cmux_ssh_auth_parent:$cmux_ssh_auth_group:$cmux_ssh_auth_started" in
              *[!A-Za-z0-9_:]*|:*|*:) continue ;;
            esac
            # A full batch is a successful partial transaction. Later
            # transactions resnapshot and continue with the remaining set.
            cmux_ssh_auth_stop_budget_allows_signal || break
            cmux_ssh_auth_expected_identity="$cmux_ssh_auth_group|$cmux_ssh_auth_started"
            cmux_ssh_auth_current_identity=$(cmux_ssh_auth_stable_identity \
              "$cmux_ssh_auth_pid")
            if [ "$cmux_ssh_auth_current_identity" != "$cmux_ssh_auth_expected_identity" ]; then
              continue
            fi
            # Publish the exact resume identity after validation and before
            # STOP. A replacement PID cannot match the stable journal key.
            printf '%s %s %s %s\n' "$cmux_ssh_auth_pid" "$cmux_ssh_auth_parent" \
              "$cmux_ssh_auth_group" "$cmux_ssh_auth_started" \
              >> "$cmux_ssh_auth_signaled_processes" || return 1
            kill -STOP "$cmux_ssh_auth_pid" >/dev/null 2>&1 || continue
          done < "$cmux_ssh_auth_ordered_processes"

          cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_poststop_snapshot" || return 1
          # STOP delivery is asynchronous. Commit only when the shared snapshot
          # proves that every journaled stable identity is stopped. Otherwise
          # the caller rolls the whole journal back before retrying.
          /usr/bin/awk '
            FILENAME == ARGV[1] && NF >= 6 {
              cmux_original[$2 SUBSEP $4 SUBSEP $5] = $6
              next
            }
            FILENAME == ARGV[2] && NF >= 9 && $4 ~ /T/ && $4 !~ /Z/ {
              cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_stopped[$1 SUBSEP $3 SUBSEP cmux_started] = 1
              next
            }
            FILENAME == ARGV[3] && NF == 4 {
              cmux_key = $1 SUBSEP $3 SUBSEP $4
              if (cmux_key in cmux_stopped && cmux_key in cmux_original) {
                print $1, $2, $3, $4, cmux_original[cmux_key]
              }
            }
          ' "$cmux_ssh_auth_ordered_processes" \
            "$cmux_ssh_auth_poststop_snapshot" \
            "$cmux_ssh_auth_signaled_processes" \
            > "$cmux_ssh_auth_frozen_processes" || return 1
          cmux_ssh_auth_signaled_count=$(/usr/bin/awk \
            'NF == 4 { count += 1 } END { print count + 0 }' \
            "$cmux_ssh_auth_signaled_processes") || return 1
          cmux_ssh_auth_frozen_count=$(/usr/bin/awk \
            'NF >= 5 { count += 1 } END { print count + 0 }' \
            "$cmux_ssh_auth_frozen_processes") || return 1
          if [ "$cmux_ssh_auth_signaled_count" != \
            "$cmux_ssh_auth_frozen_count" ]; then return 1; fi
          cmux_ssh_auth_expand_owned_processes "$cmux_ssh_auth_poststop_snapshot" || return 1
          cmux_ssh_auth_select_exclusive_groups \
            "$cmux_ssh_auth_poststop_snapshot" || return 1
        }

        cmux_ssh_auth_resume_signaled_processes() {
          if [ ! -s "$cmux_ssh_auth_signaled_groups" ] && \
            [ ! -s "$cmux_ssh_auth_signaled_processes" ]; then return 0; fi
          if [ -z "${cmux_ssh_auth_process_snapshot:-}" ] || \
            [ -z "${cmux_ssh_auth_resume_groups:-}" ] || \
            [ -z "${cmux_ssh_auth_individual_processes:-}" ]; then return 1; fi

          cmux_ssh_auth_rollback_now="$(cmux_ssh_auth_now_millis)" || return 1
          case "$cmux_ssh_auth_rollback_now" in ''|*[!0-9]*) return 1 ;; esac
          case "${cmux_ssh_auth_hard_deadline_millis:-}" in
            ''|*[!0-9]*)
              cmux_ssh_auth_rollback_deadline_millis=$((
                cmux_ssh_auth_rollback_now + 500
              ))
              ;;
            *)
              # Rollback gets one shared 500 ms safety margin after the hard
              # cleanup deadline. Repeated EXIT paths cannot extend it.
              cmux_ssh_auth_rollback_deadline_millis=$((
                cmux_ssh_auth_hard_deadline_millis + 500
              ))
              ;;
          esac
          if [ "$cmux_ssh_auth_rollback_now" -ge \
            "$cmux_ssh_auth_rollback_deadline_millis" ]; then return 1; fi
          cmux_ssh_auth_take_process_snapshot_until \
            "$cmux_ssh_auth_process_snapshot" \
            "$cmux_ssh_auth_rollback_deadline_millis" || return 1
          cmux_ssh_auth_frozen_records="${cmux_ssh_auth_frozen_processes:-}"
          if [ -z "$cmux_ssh_auth_frozen_records" ] || \
            [ ! -s "$cmux_ssh_auth_frozen_records" ]; then
            cmux_ssh_auth_frozen_records=/dev/null
          fi
          cmux_ssh_auth_group_records="$cmux_ssh_auth_signaled_groups"
          if [ ! -s "$cmux_ssh_auth_group_records" ]; then
            cmux_ssh_auth_group_records=/dev/null
          fi
          cmux_ssh_auth_process_records="$cmux_ssh_auth_signaled_processes"
          if [ ! -s "$cmux_ssh_auth_process_records" ]; then
            cmux_ssh_auth_process_records=/dev/null
          fi
          : > "$cmux_ssh_auth_resume_groups" || return 1
          : > "$cmux_ssh_auth_individual_processes" || return 1

          # Join both journals against one stopped-process snapshot. Stable
          # identity ignores reparentable PPID, and group output is deduplicated.
          /usr/bin/awk \
            -v cmux_groups="$cmux_ssh_auth_resume_groups" \
            -v cmux_pids="$cmux_ssh_auth_individual_processes" '
            function cmux_numeric(value) {
              return value ~ /^[0-9]+$/ && value != 0
            }
            function cmux_started(value) {
              return value ~ /^[A-Za-z0-9_:]+$/
            }
            FILENAME == ARGV[1] && NF >= 9 && $4 ~ /T/ && $4 !~ /Z/ {
              cmux_start = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_current[$1 SUBSEP $3 SUBSEP cmux_start] = 1
              next
            }
            FILENAME == ARGV[2] {
              if (NF == 4 && cmux_numeric($1) && cmux_numeric($2) &&
                  $3 ~ /^[0-9]+$/ && cmux_started($4)) {
                cmux_group_witness[$1 SUBSEP $2 SUBSEP $4] = 1
              } else if (NF == 1 && cmux_numeric($1)) {
                cmux_legacy_group[$1] = 1
              }
              next
            }
            FILENAME == ARGV[3] {
              if (NF == 4 && cmux_numeric($1) && $2 ~ /^[0-9]+$/ &&
                  cmux_numeric($3) && cmux_started($4)) {
                cmux_pid_witness[$1 SUBSEP $3 SUBSEP $4] = 1
              } else if (NF == 1 && cmux_numeric($1)) {
                cmux_legacy_pid[$1] = 1
              }
              next
            }
            FILENAME == ARGV[4] && NF >= 5 && cmux_numeric($1) &&
                $2 ~ /^[0-9]+$/ && cmux_numeric($3) && cmux_started($4) {
              if ($3 in cmux_legacy_group) {
                cmux_group_witness[$3 SUBSEP $1 SUBSEP $4] = 1
              }
              if ($1 in cmux_legacy_pid) {
                cmux_pid_witness[$1 SUBSEP $3 SUBSEP $4] = 1
              }
              next
            }
            END {
              for (cmux_key in cmux_group_witness) {
                split(cmux_key, cmux_fields, SUBSEP)
                cmux_current_key = cmux_fields[2] SUBSEP cmux_fields[1] SUBSEP cmux_fields[3]
                if (cmux_current_key in cmux_current) {
                  cmux_resume_group[cmux_fields[1]] = 1
                }
              }
              for (cmux_key in cmux_pid_witness) {
                if (cmux_key in cmux_current) {
                  split(cmux_key, cmux_fields, SUBSEP)
                  cmux_resume_pid[cmux_fields[1]] = cmux_fields[2]
                }
              }
              for (cmux_group in cmux_resume_group) print cmux_group > cmux_groups
              for (cmux_pid in cmux_resume_pid) {
                if (!(cmux_resume_pid[cmux_pid] in cmux_resume_group)) {
                  print cmux_pid > cmux_pids
                }
              }
            }
          ' "$cmux_ssh_auth_process_snapshot" \
            "$cmux_ssh_auth_group_records" \
            "$cmux_ssh_auth_process_records" \
            "$cmux_ssh_auth_frozen_records" || return 1
          /usr/bin/sort -un -o "$cmux_ssh_auth_resume_groups" \
            "$cmux_ssh_auth_resume_groups" || return 1
          /usr/bin/sort -un -o "$cmux_ssh_auth_individual_processes" \
            "$cmux_ssh_auth_individual_processes" || return 1

          cmux_ssh_auth_rollback_signal_count=0
          cmux_ssh_auth_rollback_signal_budget=0
          while IFS= read -r cmux_ssh_auth_resume_group; do
            case "$cmux_ssh_auth_resume_group" in ''|0|*[!0-9]*) continue ;; esac
            if [ "$cmux_ssh_auth_rollback_signal_count" -ge 1024 ]; then return 1; fi
            if [ "$cmux_ssh_auth_rollback_signal_budget" -le 0 ]; then
              cmux_ssh_auth_rollback_now="$(cmux_ssh_auth_now_millis)" || return 1
              if [ "$cmux_ssh_auth_rollback_now" -ge \
                "$cmux_ssh_auth_rollback_deadline_millis" ]; then return 1; fi
              cmux_ssh_auth_rollback_signal_budget=63
            else
              cmux_ssh_auth_rollback_signal_budget=$((
                cmux_ssh_auth_rollback_signal_budget - 1
              ))
            fi
            kill -CONT -- "-$cmux_ssh_auth_resume_group" >/dev/null 2>&1 || true
            cmux_ssh_auth_rollback_signal_count=$((
              cmux_ssh_auth_rollback_signal_count + 1
            ))
          done < "$cmux_ssh_auth_resume_groups"
          while IFS= read -r cmux_ssh_auth_pid; do
            case "$cmux_ssh_auth_pid" in ''|0|*[!0-9]*) continue ;; esac
            if [ "$cmux_ssh_auth_rollback_signal_count" -ge 1024 ]; then return 1; fi
            if [ "$cmux_ssh_auth_rollback_signal_budget" -le 0 ]; then
              cmux_ssh_auth_rollback_now="$(cmux_ssh_auth_now_millis)" || return 1
              if [ "$cmux_ssh_auth_rollback_now" -ge \
                "$cmux_ssh_auth_rollback_deadline_millis" ]; then return 1; fi
              cmux_ssh_auth_rollback_signal_budget=63
            else
              cmux_ssh_auth_rollback_signal_budget=$((
                cmux_ssh_auth_rollback_signal_budget - 1
              ))
            fi
            kill -CONT "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
            cmux_ssh_auth_rollback_signal_count=$((
              cmux_ssh_auth_rollback_signal_count + 1
            ))
          done < "$cmux_ssh_auth_individual_processes"
          return 0
        }

        cmux_ssh_auth_force_frozen_processes() {
          cmux_ssh_auth_deadline_allows_work || return 1
          if [ ! -s "$cmux_ssh_auth_frozen_processes" ] && \
            [ ! -s "$cmux_ssh_auth_owned_groups" ]; then
            if [ -n "${cmux_ssh_auth_owned_processes:-}" ] && \
              [ -s "$cmux_ssh_auth_owned_processes" ]; then return 1; fi
            return 0
          fi
          cmux_ssh_auth_force_snapshot="${1:-}"
          if [ -z "$cmux_ssh_auth_force_snapshot" ]; then
            cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" || return 1
            cmux_ssh_auth_force_snapshot="$cmux_ssh_auth_process_snapshot"
          fi
          cmux_ssh_auth_filter_current_processes "$cmux_ssh_auth_force_snapshot" \
            "$cmux_ssh_auth_frozen_processes" \
            "$cmux_ssh_auth_next_owned_processes" 1 || return 1
          cmux_ssh_auth_frozen_expected=$(/usr/bin/awk 'NF >= 5 { count += 1 } END { print count + 0 }' \
            "$cmux_ssh_auth_frozen_processes") || return 1
          cmux_ssh_auth_frozen_current=$(/usr/bin/awk 'NF >= 5 { count += 1 } END { print count + 0 }' \
            "$cmux_ssh_auth_next_owned_processes") || return 1
          if [ "$cmux_ssh_auth_frozen_expected" -gt 1024 ]; then return 1; fi
          if [ -n "${cmux_ssh_auth_owned_processes:-}" ] && \
            [ -f "$cmux_ssh_auth_owned_processes" ]; then
            # A batch may be a strict subset of the owned closure, but every
            # frozen identity must still belong to that closure.
            /usr/bin/awk '
              FILENAME == ARGV[1] && NF >= 5 {
                cmux_owned[$1 SUBSEP $3 SUBSEP $4] = 1
                next
              }
              FILENAME == ARGV[2] && NF >= 5 {
                if (!(($1 SUBSEP $3 SUBSEP $4) in cmux_owned)) exit 1
              }
            ' "$cmux_ssh_auth_owned_processes" \
              "$cmux_ssh_auth_frozen_processes" || return 1
          fi
          if [ "$cmux_ssh_auth_frozen_current" != "$cmux_ssh_auth_frozen_expected" ]; then
            return 1
          fi

          # Every signal still participates in the hard deadline. The helper
          # amortizes its clock reads while keeping each kill operation bounded.
          while IFS= read -r cmux_ssh_auth_group; do
            cmux_ssh_auth_deadline_allows_signal || return 1
            case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) return 1 ;; esac
            kill -KILL -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || return 1
          done < "$cmux_ssh_auth_owned_groups"
          /bin/cp "$cmux_ssh_auth_next_owned_processes" \
            "$cmux_ssh_auth_individual_processes" || return 1
          while read -r cmux_ssh_auth_pid cmux_ssh_auth_parent cmux_ssh_auth_group \
            cmux_ssh_auth_started cmux_ssh_auth_state; do
            cmux_ssh_auth_deadline_allows_signal || return 1
            case "$cmux_ssh_auth_pid:$cmux_ssh_auth_parent:$cmux_ssh_auth_group:$cmux_ssh_auth_started" in
              *[!A-Za-z0-9_:]*|:*|*:) return 1 ;;
            esac
            kill -KILL "$cmux_ssh_auth_pid" >/dev/null 2>&1 || return 1
          done < "$cmux_ssh_auth_individual_processes"
        }

        cmux_ssh_auth_freeze_and_force_owned_processes() {
          # Refresh membership immediately before freezing a bounded batch.
          cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" || return 1
          cmux_ssh_auth_expand_owned_processes || return 1
          cmux_ssh_auth_freeze_owned_processes || return 1
          cmux_ssh_auth_force_frozen_processes "$cmux_ssh_auth_poststop_snapshot" || return 1

          # KILL commits this batch. A fresh snapshot distinguishes complete
          # cleanup from a successful partial batch without deleting ownership
          # state for processes that remain.
          cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" || return 1
          cmux_ssh_auth_expand_owned_processes || return 1
          if [ -s "$cmux_ssh_auth_owned_processes" ]; then return 2; fi
          return 0
        }

        cmux_ssh_auth_run_cleanup_transactions() {
          cmux_ssh_auth_transaction_attempt=0
          while [ "$cmux_ssh_auth_transaction_attempt" -lt 4 ]; do
            cmux_ssh_auth_deadline_allows_work || return 1
            cmux_ssh_auth_reset_stop_budget
            : > "$cmux_ssh_auth_frozen_processes" || return 1
            : > "$cmux_ssh_auth_signaled_groups" || return 1
            : > "$cmux_ssh_auth_signaled_processes" || return 1
            cmux_ssh_auth_transaction_status=0
            cmux_ssh_auth_freeze_and_force_owned_processes || \
              cmux_ssh_auth_transaction_status=$?
            case "$cmux_ssh_auth_transaction_status" in
              0) return 0 ;;
              2)
                # The stopped identities were KILLed and the fresh snapshot
                # confirmed that a smaller owned set remains. Their journals
                # are committed and must not be rolled back.
                : > "$cmux_ssh_auth_frozen_processes" || return 1
                : > "$cmux_ssh_auth_signaled_groups" || return 1
                : > "$cmux_ssh_auth_signaled_processes" || return 1
                ;;
              *)
                # Never overwrite a STOP journal until every matching survivor
                # has been resumed. The EXIT trap keeps the journal for recovery
                # if the bounded rollback itself cannot finish.
                cmux_ssh_auth_resume_signaled_processes || return 1
                ;;
            esac
            cmux_ssh_auth_transaction_attempt=$((cmux_ssh_auth_transaction_attempt + 1))
          done
          return 1
        }
        """#
    }
}
