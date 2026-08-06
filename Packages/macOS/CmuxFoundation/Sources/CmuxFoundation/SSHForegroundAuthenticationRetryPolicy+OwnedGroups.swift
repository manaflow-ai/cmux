extension SSHForegroundAuthenticationRetryPolicy {
    func ownedProcessGroupTerminationShellFunctions() -> String {
        #"""
        cmux_ssh_auth_take_process_snapshot() {
          /usr/bin/env LC_ALL=C LANG=C /bin/ps -axo pid=,ppid=,pgid=,state=,lstart= \
            > "$cmux_ssh_auth_process_snapshot" 2>/dev/null
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
          ' "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_process_snapshot" | \
            /usr/bin/sort -n -k1,1 > "$cmux_ssh_auth_next_owned_processes"
          /bin/mv -f -- "$cmux_ssh_auth_next_owned_processes" "$cmux_ssh_auth_owned_processes"
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
              if ($3 in cmux_candidate &&
                  !(($1 SUBSEP $2 SUBSEP $3 SUBSEP cmux_started) in cmux_owned)) {
                cmux_mixed[$3] = 1
              }
            }
            END {
              for (cmux_group in cmux_candidate) {
                if (!(cmux_group in cmux_mixed)) print cmux_group
              }
            }
          ' "$cmux_ssh_auth_owned_processes" "$cmux_ssh_auth_process_snapshot" | \
            /usr/bin/sort -un > "$cmux_ssh_auth_owned_groups"
        }

        cmux_ssh_auth_freeze_owned_processes() {
          cmux_ssh_auth_select_exclusive_groups || return 1
          while IFS= read -r cmux_ssh_auth_group; do
            case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) continue ;; esac
            /bin/kill -STOP -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_owned_groups"

          /usr/bin/awk '
            FILENAME == ARGV[1] { cmux_exclusive[$1] = 1; next }
            !($3 in cmux_exclusive) { print $1 }
          ' "$cmux_ssh_auth_owned_groups" "$cmux_ssh_auth_owned_processes" | \
            while IFS= read -r cmux_ssh_auth_pid; do
              case "$cmux_ssh_auth_pid" in ''|0|*[!0-9]*) continue ;; esac
              /bin/kill -STOP "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
            done
        }

        cmux_ssh_auth_force_owned_processes() {
          while IFS= read -r cmux_ssh_auth_group; do
            case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) continue ;; esac
            /bin/kill -KILL -- "-$cmux_ssh_auth_group" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_owned_groups"

          /usr/bin/awk '
            FILENAME == ARGV[1] { cmux_exclusive[$1] = 1; next }
            !($3 in cmux_exclusive) { print $1 }
          ' "$cmux_ssh_auth_owned_groups" "$cmux_ssh_auth_owned_processes" | \
            while IFS= read -r cmux_ssh_auth_pid; do
              case "$cmux_ssh_auth_pid" in ''|0|*[!0-9]*) continue ;; esac
              /bin/kill -KILL "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
            done
        }
        """#
    }
}
