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
            # bounded file append. Refresh the wall clock every fourth signal
            # without paying one process launch per PID.
            cmux_ssh_auth_signal_budget=3
          else
            cmux_ssh_auth_signal_budget=$((cmux_ssh_auth_signal_budget - 1))
          fi
          return 0
        }

        cmux_ssh_auth_take_process_snapshot() {
          cmux_ssh_auth_snapshot_now="$(cmux_ssh_auth_now_millis)" || return 1
          case "$cmux_ssh_auth_snapshot_now:$cmux_ssh_auth_deadline_millis" in
            *[!0-9:]*|:*|*:) return 1 ;;
          esac
          cmux_ssh_auth_snapshot_remaining=$((
            cmux_ssh_auth_deadline_millis - cmux_ssh_auth_snapshot_now
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
            > "$1" 2>/dev/null
        }

        cmux_ssh_auth_expand_owned_processes() {
          /usr/bin/awk -v cmux_root_group="$cmux_ssh_auth_owned_group" '
            FILENAME == ARGV[1] {
              cmux_previous[$1 SUBSEP $4] = 1
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
                  (($1 SUBSEP cmux_started[cmux_pid]) in cmux_previous)) {
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
          ' "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_process_snapshot" \
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
            }
            END {
              for (cmux_pid in cmux_record) {
                cmux_next_sibling[cmux_pid] = cmux_first_child[cmux_parent[cmux_pid]]
                cmux_first_child[cmux_parent[cmux_pid]] = cmux_pid
              }
              for (cmux_pid in cmux_record) {
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
              for (cmux_pid in cmux_record) {
                print cmux_depth[cmux_pid] + 0, cmux_record[cmux_pid]
              }
            }
          ' "$1" > "$2" || return 1
          /usr/bin/sort -k1,1nr -k2,2nr -o "$2" "$2"
        }

        cmux_ssh_auth_select_exclusive_groups() {
          /usr/bin/awk -v cmux_caller_group="$cmux_ssh_auth_caller_group" '
            FILENAME == ARGV[1] {
              cmux_owned[$1 SUBSEP $2 SUBSEP $3 SUBSEP $4] = 1
              if ($3 != 0 && $3 != cmux_caller_group) cmux_candidate[$3] = 1
              next
            }
            NF >= 9 && $4 !~ /Z/ {
              cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
              if ($3 in cmux_candidate) {
                cmux_seen[$3] = 1
                if (!(($1 SUBSEP $2 SUBSEP $3 SUBSEP cmux_started) in cmux_owned)) {
                  cmux_mixed[$3] = 1
                }
              }
            }
            END {
              for (cmux_group in cmux_candidate) {
                if (cmux_group in cmux_seen && !(cmux_group in cmux_mixed)) print cmux_group
              }
            }
          ' "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_process_snapshot" \
            > "$cmux_ssh_auth_next_owned_groups" || return 1
          /usr/bin/sort -un -o "$cmux_ssh_auth_next_owned_groups" \
            "$cmux_ssh_auth_next_owned_groups" || return 1
          /bin/mv -f -- "$cmux_ssh_auth_next_owned_groups" "$cmux_ssh_auth_owned_groups"
        }

        cmux_ssh_auth_filter_current_processes() {
          cmux_ssh_auth_filter_snapshot="$1"
          cmux_ssh_auth_filter_candidates="$2"
          cmux_ssh_auth_filter_output="$3"
          cmux_ssh_auth_filter_require_stopped="$4"
          /usr/bin/awk -v cmux_require_stopped="$cmux_ssh_auth_filter_require_stopped" '
            FILENAME == ARGV[1] && NF >= 9 && $4 !~ /Z/ {
              cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_current[$1 SUBSEP $2 SUBSEP $3 SUBSEP cmux_started] = $4
              next
            }
            FILENAME == ARGV[2] && NF >= 5 {
              cmux_key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
              if (cmux_key in cmux_current &&
                  (!cmux_require_stopped || cmux_current[cmux_key] ~ /T/)) print
            }
          ' "$cmux_ssh_auth_filter_snapshot" "$cmux_ssh_auth_filter_candidates" \
            > "$cmux_ssh_auth_filter_output"
        }

        cmux_ssh_auth_revalidate_stopped_groups() {
          /usr/bin/awk '
            FILENAME == ARGV[1] {
              cmux_owned[$1 SUBSEP $2 SUBSEP $3 SUBSEP $4] = 1
              next
            }
            FILENAME == ARGV[2] {
              cmux_candidate[$1] = 1
              next
            }
            NF >= 9 && $4 !~ /Z/ && $3 in cmux_candidate {
              cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_seen[$3] = 1
              if ($4 !~ /T/ ||
                  !(($1 SUBSEP $2 SUBSEP $3 SUBSEP cmux_started) in cmux_owned)) {
                cmux_mixed[$3] = 1
              }
            }
            END {
              for (cmux_group in cmux_candidate) {
                if (cmux_group in cmux_seen && !(cmux_group in cmux_mixed)) print cmux_group
              }
            }
          ' "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_owned_groups" \
            "$cmux_ssh_auth_poststop_snapshot" > "$cmux_ssh_auth_next_owned_groups" || return 1
          /usr/bin/sort -un -o "$cmux_ssh_auth_next_owned_groups" \
            "$cmux_ssh_auth_next_owned_groups" || return 1

          /usr/bin/awk '
            FILENAME == ARGV[1] { cmux_valid[$1] = 1; next }
            FILENAME == ARGV[2] { cmux_candidate[$1] = 1; next }
            END {
              for (cmux_group in cmux_candidate) {
                if (!(cmux_group in cmux_valid)) print cmux_group
              }
            }
          ' "$cmux_ssh_auth_next_owned_groups" "$cmux_ssh_auth_owned_groups" \
            > "$cmux_ssh_auth_resume_groups" || return 1
          while IFS= read -r cmux_ssh_auth_group; do
            case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) continue ;; esac
            /bin/kill -CONT -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_resume_groups"

          /bin/mv -f -- "$cmux_ssh_auth_next_owned_groups" "$cmux_ssh_auth_owned_groups"
        }

        cmux_ssh_auth_freeze_owned_processes() {
          cmux_ssh_auth_deadline_allows_work || return 1
          cmux_ssh_auth_select_exclusive_groups || return 1

          while IFS= read -r cmux_ssh_auth_group; do
            cmux_ssh_auth_deadline_allows_signal || return 1
            case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) continue ;; esac
            if /bin/kill -STOP -- "-$cmux_ssh_auth_group" >/dev/null 2>&1; then
              if ! printf '%s\n' "$cmux_ssh_auth_group" >> "$cmux_ssh_auth_signaled_groups"; then
                /bin/kill -CONT -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || true
                return 1
              fi
            fi
          done < "$cmux_ssh_auth_owned_groups"

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
            /bin/kill -STOP "$cmux_ssh_auth_pid" >/dev/null 2>&1 || continue
            if ! printf '%s\n' "$cmux_ssh_auth_pid" >> "$cmux_ssh_auth_signaled_processes"; then
              /bin/kill -CONT "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
              return 1
            fi
            if ! printf '%s %s %s %s %s\n' "$cmux_ssh_auth_pid" \
              "$cmux_ssh_auth_parent" "$cmux_ssh_auth_group" "$cmux_ssh_auth_started" \
              "$cmux_ssh_auth_state" >> "$cmux_ssh_auth_frozen_processes"; then
              /bin/kill -CONT "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
              return 1
            fi
          done < "$cmux_ssh_auth_ordered_processes"

          cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_poststop_snapshot" || return 1
          cmux_ssh_auth_revalidate_stopped_groups || return 1
          /usr/bin/awk '
            FILENAME == ARGV[1] { cmux_valid_group[$1] = 1; next }
            FILENAME == ARGV[2] && NF >= 9 && $4 ~ /T/ && $4 !~ /Z/ {
              cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_stopped[$1 SUBSEP $2 SUBSEP $3 SUBSEP cmux_started] = 1
              next
            }
            FILENAME == ARGV[3] {
              cmux_identity = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
              if ($3 in cmux_valid_group && cmux_identity in cmux_stopped) print
            }
          ' "$cmux_ssh_auth_owned_groups" "$cmux_ssh_auth_poststop_snapshot" \
            "$cmux_ssh_auth_owned_processes" >> "$cmux_ssh_auth_frozen_processes" || return 1
        }

        cmux_ssh_auth_force_owned_processes() {
          cmux_ssh_auth_deadline_allows_work || return 1
          cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" || return 1
          cmux_ssh_auth_expand_owned_processes || return 1
          cmux_ssh_auth_select_exclusive_groups || return 1

          while IFS= read -r cmux_ssh_auth_group; do
            cmux_ssh_auth_deadline_allows_signal || return 1
            case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) continue ;; esac
            /bin/kill -KILL -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || \
              /bin/kill -CONT -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_owned_groups"

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
            /bin/kill -KILL "$cmux_ssh_auth_pid" >/dev/null 2>&1 || \
              /bin/kill -CONT "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_ordered_processes"
        }

        cmux_ssh_auth_resume_signaled_processes() {
          if [ -s "$cmux_ssh_auth_signaled_groups" ]; then
            while IFS= read -r cmux_ssh_auth_group; do
              case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) continue ;; esac
              /bin/kill -CONT -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || true
            done < "$cmux_ssh_auth_signaled_groups"
          fi
          if [ -s "$cmux_ssh_auth_signaled_processes" ]; then
            while IFS= read -r cmux_ssh_auth_pid; do
              case "$cmux_ssh_auth_pid" in ''|0|*[!0-9]*) continue ;; esac
              /bin/kill -CONT "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
            done < "$cmux_ssh_auth_signaled_processes"
          fi
        }

        cmux_ssh_auth_force_frozen_processes() {
          cmux_ssh_auth_deadline_allows_work || return 1
          if [ ! -s "$cmux_ssh_auth_frozen_processes" ]; then return 0; fi
          cmux_ssh_auth_take_process_snapshot "$cmux_ssh_auth_process_snapshot" || return 1
          cmux_ssh_auth_filter_current_processes "$cmux_ssh_auth_process_snapshot" \
            "$cmux_ssh_auth_frozen_processes" \
            "$cmux_ssh_auth_next_owned_processes" 1 || return 1
          cmux_ssh_auth_frozen_expected=$(/usr/bin/awk 'NF >= 5 { count += 1 } END { print count + 0 }' \
            "$cmux_ssh_auth_frozen_processes") || return 1
          cmux_ssh_auth_frozen_current=$(/usr/bin/awk 'NF >= 5 { count += 1 } END { print count + 0 }' \
            "$cmux_ssh_auth_next_owned_processes") || return 1
          cmux_ssh_auth_order_children_first "$cmux_ssh_auth_next_owned_processes" \
            "$cmux_ssh_auth_ordered_processes" || return 1
          if [ ! -s "$cmux_ssh_auth_ordered_processes" ]; then return 1; fi
          if [ "$cmux_ssh_auth_frozen_current" = "$cmux_ssh_auth_frozen_expected" ]; then
            cmux_ssh_auth_frozen_incomplete=0
          else
            cmux_ssh_auth_frozen_incomplete=1
          fi
          while read -r cmux_ssh_auth_depth cmux_ssh_auth_pid cmux_ssh_auth_parent \
            cmux_ssh_auth_group cmux_ssh_auth_started cmux_ssh_auth_state; do
            cmux_ssh_auth_deadline_allows_signal || return 1
            case "$cmux_ssh_auth_pid:$cmux_ssh_auth_parent:$cmux_ssh_auth_group:$cmux_ssh_auth_started" in
              *[!A-Za-z0-9_:]*|:*|*:) cmux_ssh_auth_frozen_incomplete=1; continue ;;
            esac
            /bin/kill -KILL "$cmux_ssh_auth_pid" >/dev/null 2>&1 || return 1
          done < "$cmux_ssh_auth_ordered_processes"
          [ "$cmux_ssh_auth_frozen_incomplete" = 0 ]
        }
        """#
    }
}
