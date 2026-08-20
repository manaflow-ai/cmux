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
          cmux_ssh_auth_stop_budget=32
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
            use strict;
            use warnings;
            use Errno qw(ESRCH);
            my $timeout_millis = shift;
            my $owned_group = shift;
            my $caller_group = shift;
            my $owned_records = shift;
            exit 1 unless defined($timeout_millis) &&
              $timeout_millis =~ /\A[1-9][0-9]*\z/;
            exit 1 unless defined($owned_group) && $owned_group =~ /\A[0-9]+\z/;
            exit 1 unless defined($caller_group) && $caller_group =~ /\A[0-9]+\z/;
            exit 1 unless defined($owned_records) && length($owned_records) > 0;
            local $SIG{ALRM} = sub { exit 124 };
            alarm($timeout_millis / 1000);

            # Query only the isolated authentication group, previously owned
            # identities, and their descendants. Candidate groups are then
            # expanded solely to prove whether every member is owned. This
            # keeps cleanup proportional to its process tree instead of every
            # process on the machine.
            my $PROC_PGRP_ONLY = 2;
            my $PROC_PPID_ONLY = 6;
            my $MAX_OWNED = 4096;
            my $MAX_RELATED = 8192;
            my $pid_buffer_bytes = 4 * ($MAX_RELATED + 1);
            my %state = (1 => "I", 2 => "R", 3 => "S", 4 => "T", 5 => "Z");

            my $list_pids = sub {
              my ($type, $value) = @_;
              my $pid_buffer = "\0" x $pid_buffer_bytes;
              my $pid_bytes = syscall(
                336, 1, $type, $value, 0, $pid_buffer, length($pid_buffer)
              );
              die "bounded proc list failed" if $pid_bytes < 0 ||
                $pid_bytes >= length($pid_buffer) || ($pid_bytes % 4) != 0;
              my %seen;
              return grep { $_ != 0 && !$seen{$_}++ }
                unpack("L<*", substr($pid_buffer, 0, $pid_bytes));
            };

            my $read_info = sub {
              my ($pid) = @_;
              # Darwin proc_bsdinfo uses MAXCOMLEN == 16: twelve 4-byte
              # fields, pbi_comm[16], pbi_name[32], then pbi_nfiles[4].
              # Therefore pbi_pgid starts at 100 and the 136-byte structure
              # ends with pbi_start_tvsec/usec at offsets 120 and 128.
              my $buffer = "\0" x 136;
              my $size = syscall(336, 2, $pid, 3, 0, $buffer, 136);
              return undef unless $size == 136;
              my $status = unpack("L<", substr($buffer, 4, 4));
              my $observed_pid = unpack("L<", substr($buffer, 12, 4));
              my $parent = unpack("L<", substr($buffer, 16, 4));
              my $group = unpack("L<", substr($buffer, 100, 4));
              my $seconds = unpack("Q<", substr($buffer, 120, 8));
              my $microseconds = unpack("Q<", substr($buffer, 128, 8));
              return undef if $observed_pid != $pid || $group == 0 || $seconds == 0 ||
                $microseconds >= 1_000_000;
              return {
                pid => $pid,
                parent => $parent,
                group => $group,
                state => ($state{$status} // "U"),
                started => "K_${seconds}_${microseconds}",
              };
            };

            my $relevant_info = sub {
              my ($pid) = @_;
              my $info = $read_info->($pid);
              return $info if defined($info);
              $! = 0;
              my $alive = kill 0, $pid;
              return undef if !$alive && $! == ESRCH;
              die "cannot inspect live related process";
            };

            my %prior;
            open(my $owned_file, "<", $owned_records) or exit 1;
            while (my $line = <$owned_file>) {
              my @fields = split(/\s+/, $line);
              my ($pid, $group, $started) = @fields[0, 2, 3];
              next unless defined($pid) && defined($group) && defined($started);
              next unless $pid =~ /\A[1-9][0-9]*\z/ &&
                $group =~ /\A[1-9][0-9]*\z/ &&
                $started =~ /\A[A-Za-z0-9_:]+\z/;
              $prior{$pid} = "$group|$started";
              die "too many prior owned processes" if keys(%prior) > $MAX_OWNED;
            }
            close($owned_file) or exit 1;

            my %owned;
            my @queue;
            my $add_owned = sub {
              my ($info) = @_;
              return unless defined($info) && $info->{state} ne "Z";
              return if exists($owned{$info->{pid}});
              die "owned process tree exceeds bound" if keys(%owned) >= $MAX_OWNED;
              $owned{$info->{pid}} = $info;
              push @queue, $info->{pid};
            };

            for my $pid (sort { $a <=> $b } keys(%prior)) {
              my $info = $relevant_info->($pid);
              next unless defined($info);
              next unless "$info->{group}|$info->{started}" eq $prior{$pid};
              $add_owned->($info);
            }
            if ($owned_group != 0) {
              for my $pid ($list_pids->($PROC_PGRP_ONLY, $owned_group)) {
                my $info = $relevant_info->($pid);
                next unless defined($info) && $info->{group} == $owned_group;
                $add_owned->($info);
              }
            }
            for (my $index = 0; $index < @queue; $index++) {
              my $parent = $queue[$index];
              for my $pid ($list_pids->($PROC_PPID_ONLY, $parent)) {
                my $info = $relevant_info->($pid);
                next unless defined($info) && $info->{parent} == $parent;
                $add_owned->($info);
              }
            }

            my %related = %owned;
            my %candidate_groups;
            for my $info (values(%owned)) {
              my $group = $info->{group};
              $candidate_groups{$group} = 1
                if $group != 0 && $group != $caller_group;
            }
            for my $group (sort { $a <=> $b } keys(%candidate_groups)) {
              for my $pid ($list_pids->($PROC_PGRP_ONLY, $group)) {
                my $info = $relevant_info->($pid);
                next unless defined($info) && $info->{group} == $group &&
                  $info->{state} ne "Z";
                if (!exists($related{$pid})) {
                  die "related process set exceeds bound"
                    if keys(%related) >= $MAX_RELATED;
                  $related{$pid} = $info;
                }
              }
            }

            for my $pid (sort { $a <=> $b } keys(%related)) {
              my $info = $related{$pid};
              print "$pid $info->{parent} $info->{group} $info->{state} " .
                "$info->{started}\n";
            }
            alarm(0);
          ' "$cmux_ssh_auth_snapshot_remaining" \
            "${cmux_ssh_auth_owned_group:-0}" \
            "${cmux_ssh_auth_caller_group:-0}" \
            "$cmux_ssh_auth_owned_processes" \
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
            NF >= 5 && $4 !~ /Z/ {
              cmux_pid = $1
              cmux_parent[cmux_pid] = $2
              cmux_group[cmux_pid] = $3
              cmux_state[cmux_pid] = $4
              cmux_started[cmux_pid] = $5
              if (NF >= 9) {
                cmux_started[cmux_pid] = $5 "_" $6 "_" $7 "_" $8 "_" $9
              }
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
            FILENAME == ARGV[2] && NF >= 5 && $4 !~ /Z/ {
              cmux_started = $5
              if (NF >= 9) cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
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
            FILENAME == ARGV[1] && NF >= 5 && $4 !~ /Z/ {
              cmux_started = $5
              if (NF >= 9) cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
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
          # New cleanup transactions always use bounded, exact per-process
          # signals. A process-group STOP can include a child that forks after
          # the snapshot and therefore has no durable rollback identity.
          : > "$cmux_ssh_auth_owned_groups" || return 1
          : > "$cmux_ssh_auth_signaled_groups" || return 1
          : > "$cmux_ssh_auth_frozen_processes" || return 1

          # Every fresh transaction uses exact process identities. The small
          # batch cap keeps validation and rollback within the shared deadline.
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
            case "$cmux_ssh_auth_state" in
              ''|*[!A-Za-z+\<\>]*) continue ;;
            esac
            # A full batch is a successful partial transaction. Later
            # transactions resnapshot and continue with the remaining set.
            cmux_ssh_auth_stop_budget_allows_signal || break
            cmux_ssh_auth_expected_identity="$cmux_ssh_auth_group|$cmux_ssh_auth_started"
            if cmux_ssh_auth_current_identity=$(cmux_ssh_auth_stable_identity \
              "$cmux_ssh_auth_pid" "$cmux_ssh_auth_deadline_millis"); then
              :
            else
              case "$?" in 124) return 1 ;; *) continue ;; esac
            fi
            if [ "$cmux_ssh_auth_current_identity" != "$cmux_ssh_auth_expected_identity" ]; then
              continue
            fi
            # Publish the exact resume identity and its pre-STOP state after
            # validation. A replacement PID cannot match the stable key, and
            # rollback will not wake a process that was already stopped.
            printf '%s %s %s %s %s\n' "$cmux_ssh_auth_pid" "$cmux_ssh_auth_parent" \
              "$cmux_ssh_auth_group" "$cmux_ssh_auth_started" \
              "$cmux_ssh_auth_state" \
              >> "$cmux_ssh_auth_signaled_processes" || return 1
            kill -STOP "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
          done < "$cmux_ssh_auth_ordered_processes"

          # STOP can remain pending on a zsh vfork child until its parent has
          # stopped. Confirm the whole batch. If an exact child is still live
          # after its exact parent is stopped, CONT cancels the stale pending
          # STOP and the following STOP arms a fresh delivery.
          while :; do
            cmux_ssh_auth_take_process_snapshot \
              "$cmux_ssh_auth_poststop_snapshot" || return 1
            : > "$cmux_ssh_auth_next_owned_processes" || return 1
            if /usr/bin/awk \
              -v cmux_unconfirmed_path="$cmux_ssh_auth_next_owned_processes" '
              FILENAME == ARGV[1] && NF >= 6 {
                cmux_key = $2 SUBSEP $4 SUBSEP $5
                cmux_original[cmux_key] = $6
                cmux_original_key_for_pid[$2] = cmux_key
                next
              }
              FILENAME == ARGV[2] && NF >= 5 {
                cmux_started = $5
                if (NF >= 9) cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                cmux_key = $1 SUBSEP $3 SUBSEP cmux_started
                if ($4 !~ /Z/) {
                  cmux_live[cmux_key] = 1
                  cmux_current_key_for_pid[$1] = cmux_key
                }
                if ($4 ~ /T/ && $4 !~ /Z/) cmux_stopped[cmux_key] = 1
                next
              }
              FILENAME == ARGV[3] && NF >= 4 {
                cmux_key = $1 SUBSEP $3 SUBSEP $4
                if (cmux_key in cmux_live && !(cmux_key in cmux_stopped)) {
                  cmux_parent_key = cmux_original_key_for_pid[$2]
                  cmux_rearm = (cmux_parent_key != "" &&
                    cmux_current_key_for_pid[$2] == cmux_parent_key &&
                    cmux_parent_key in cmux_stopped) ? 1 : 0
                  print $1, $2, $3, $4, $5, cmux_rearm \
                    > cmux_unconfirmed_path
                  cmux_unconfirmed = 1
                }
                if (cmux_key in cmux_stopped && cmux_key in cmux_original) {
                  print $1, $2, $3, $4, cmux_original[cmux_key]
                }
              }
              END { exit(cmux_unconfirmed ? 1 : 0) }
            ' "$cmux_ssh_auth_ordered_processes" \
              "$cmux_ssh_auth_poststop_snapshot" \
              "$cmux_ssh_auth_signaled_processes" \
              > "$cmux_ssh_auth_frozen_processes"; then
              break
            fi
            cmux_ssh_auth_deadline_allows_work || return 1
            while read -r cmux_ssh_auth_pid cmux_ssh_auth_parent \
              cmux_ssh_auth_group cmux_ssh_auth_started \
              cmux_ssh_auth_state cmux_ssh_auth_rearm; do
              if [ "$cmux_ssh_auth_rearm" != 1 ]; then continue; fi
              cmux_ssh_auth_expected_identity="$cmux_ssh_auth_group|$cmux_ssh_auth_started"
              if cmux_ssh_auth_current_identity=$(cmux_ssh_auth_stable_identity \
                "$cmux_ssh_auth_pid" "$cmux_ssh_auth_deadline_millis"); then
                :
              else
                case "$?" in 124) return 1 ;; *) continue ;; esac
              fi
              if [ "$cmux_ssh_auth_current_identity" != \
                "$cmux_ssh_auth_expected_identity" ]; then continue; fi
              kill -CONT "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
              kill -STOP "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
            done < "$cmux_ssh_auth_next_owned_processes"
            /bin/sleep 0.01
          done
          cmux_ssh_auth_expand_owned_processes "$cmux_ssh_auth_poststop_snapshot" || return 1
          # A process can fork between the initial snapshot and its own STOP.
          # Roll back unless every post-STOP identity was in the exact initial set.
          /usr/bin/awk '
            FILENAME == ARGV[1] && NF >= 5 {
              cmux_initial[$1 SUBSEP $3 SUBSEP $4] = 1
              next
            }
            FILENAME == ARGV[2] && NF >= 5 {
              cmux_key = $1 SUBSEP $3 SUBSEP $4
              if (!(cmux_key in cmux_initial)) exit 1
            }
          ' "$cmux_ssh_auth_individual_processes" \
            "$cmux_ssh_auth_owned_processes" || return 1
          : > "$cmux_ssh_auth_owned_groups" || return 1
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

          # Exact journal witnesses are resume candidates even when this snapshot
          # ran before asynchronous STOP delivery. The snapshot is only needed to
          # recover descendants of a legacy group witness.
          /usr/bin/awk \
            -v cmux_groups="$cmux_ssh_auth_resume_groups" \
            -v cmux_pids="$cmux_ssh_auth_individual_processes" '
            function cmux_numeric(value) {
              return value ~ /^[0-9]+$/ && value != 0
            }
            function cmux_started(value) {
              return value ~ /^[A-Za-z0-9_:]+$/
            }
            FILENAME == ARGV[1] && NF >= 5 && $4 ~ /T/ && $4 !~ /Z/ {
              cmux_start = $5
              if (NF >= 9) cmux_start = $5 "_" $6 "_" $7 "_" $8 "_" $9
              cmux_current[$1 SUBSEP $3 SUBSEP cmux_start] = 1
              cmux_current_group[$1] = $3
              cmux_current_parent[$1] = $2
              cmux_current_started[$1] = cmux_start
              next
            }
            FILENAME == ARGV[2] {
              if ((NF == 4 || (NF == 5 && $5 ~ /^[A-Za-z+<>]+$/ && $5 !~ /T/)) &&
                  cmux_numeric($1) && cmux_numeric($2) &&
                  $3 ~ /^[0-9]+$/ && cmux_started($4)) {
                cmux_group_witness[$1 SUBSEP $2 SUBSEP $4] = 1
              } else if (NF == 1 && cmux_numeric($1)) {
                cmux_legacy_group[$1] = 1
              }
              next
            }
            FILENAME == ARGV[3] {
              if ((NF == 4 || (NF == 5 && $5 ~ /^[A-Za-z+<>]+$/ && $5 !~ /T/)) &&
                  cmux_numeric($1) && $2 ~ /^[0-9]+$/ &&
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
                cmux_resume_pid[cmux_fields[2]] = cmux_fields[1]
                cmux_resume_started[cmux_fields[2]] = cmux_fields[3]
                cmux_resume_tree[cmux_fields[2]] = cmux_fields[1]
              }
              for (cmux_key in cmux_pid_witness) {
                split(cmux_key, cmux_fields, SUBSEP)
                cmux_resume_pid[cmux_fields[1]] = cmux_fields[2]
                cmux_resume_started[cmux_fields[1]] = cmux_fields[3]
              }
              # If the first post-STOP snapshot failed, recover stopped
              # descendants from the rollback snapshot. A descendant must
              # lead to an exact stable group witness and remain in that same
              # group, so a later unrelated group joiner is not resumed.
              do {
                cmux_changed = 0
                for (cmux_pid in cmux_current_group) {
                  cmux_parent = cmux_current_parent[cmux_pid]
                  cmux_group = cmux_current_group[cmux_pid]
                  if (!(cmux_pid in cmux_resume_tree) &&
                      cmux_parent in cmux_resume_tree &&
                      cmux_resume_tree[cmux_parent] == cmux_group) {
                    cmux_resume_tree[cmux_pid] = cmux_group
                    cmux_resume_pid[cmux_pid] = cmux_group
                    cmux_resume_started[cmux_pid] = cmux_current_started[cmux_pid]
                    cmux_changed = 1
                  }
                }
              } while (cmux_changed)
              for (cmux_pid in cmux_resume_pid) {
                print cmux_pid, cmux_resume_pid[cmux_pid], \
                  cmux_resume_started[cmux_pid] > cmux_pids
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
          while read -r cmux_ssh_auth_pid cmux_ssh_auth_group \
            cmux_ssh_auth_started; do
            case "$cmux_ssh_auth_pid" in ''|0|*[!0-9]*) continue ;; esac
            case "$cmux_ssh_auth_group" in ''|0|*[!0-9]*) continue ;; esac
            case "$cmux_ssh_auth_started" in
              ''|*[!A-Za-z0-9_:]*) continue ;;
            esac
            if [ "$cmux_ssh_auth_rollback_signal_count" -ge 1024 ]; then return 1; fi
            cmux_ssh_auth_rollback_signal_count=$((
              cmux_ssh_auth_rollback_signal_count + 1
            ))
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
            cmux_ssh_auth_expected_identity="$cmux_ssh_auth_group|$cmux_ssh_auth_started"
            if cmux_ssh_auth_current_identity=$(cmux_ssh_auth_stable_identity \
              "$cmux_ssh_auth_pid" "$cmux_ssh_auth_rollback_deadline_millis"); then
              :
            else
              case "$?" in 124) return 1 ;; *) continue ;; esac
            fi
            if [ "$cmux_ssh_auth_current_identity" != \
              "$cmux_ssh_auth_expected_identity" ]; then continue; fi
            # CONT after STOP cancels a pending asynchronous STOP and is harmless
            # when the matching process has not entered the stopped state yet.
            kill -CONT "$cmux_ssh_auth_pid" >/dev/null 2>&1 || true
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
            # The post-STOP snapshot can become stale before KILL. Refresh the
            # whole group and require every live member to retain an owned,
            # stopped identity before sending the destructive group signal.
            cmux_ssh_auth_take_process_snapshot \
              "$cmux_ssh_auth_individual_processes" || return 1
            cmux_ssh_auth_group_proof_status=0
            /usr/bin/awk -v cmux_group="$cmux_ssh_auth_group" '
              FILENAME == ARGV[1] && NF >= 5 {
                cmux_owned[$1 SUBSEP $3 SUBSEP $4] = 1
                next
              }
              FILENAME == ARGV[2] && NF >= 5 && $3 == cmux_group && $4 !~ /Z/ {
                cmux_started = $5
                if (NF >= 9) cmux_started = $5 "_" $6 "_" $7 "_" $8 "_" $9
                cmux_seen += 1
                if ($4 !~ /T/ ||
                    !(($1 SUBSEP $3 SUBSEP cmux_started) in cmux_owned)) {
                  cmux_invalid = 1
                }
              }
              END {
                if (cmux_invalid || cmux_seen > 1024) exit 1
                if (cmux_seen == 0) exit 2
              }
            ' "$cmux_ssh_auth_owned_processes" \
              "$cmux_ssh_auth_individual_processes" || \
              cmux_ssh_auth_group_proof_status=$?
            case "$cmux_ssh_auth_group_proof_status" in
              0) ;;
              2) continue ;;
              *) return 1 ;;
            esac
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
            cmux_ssh_auth_expected_identity="$cmux_ssh_auth_group|$cmux_ssh_auth_started"
            if cmux_ssh_auth_current_identity=$(cmux_ssh_auth_stable_identity \
              "$cmux_ssh_auth_pid" "$cmux_ssh_auth_deadline_millis"); then
              :
            else
              case "$?" in 124) return 1 ;; *) continue ;; esac
            fi
            if [ "$cmux_ssh_auth_current_identity" != \
              "$cmux_ssh_auth_expected_identity" ]; then return 1; fi
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
          # A prior bounded rollback can leave its write-ahead STOP journals for
          # the EXIT or recovery retry. Resume those exact identities before a
          # new transaction clears and replaces the journals.
          if [ -s "$cmux_ssh_auth_frozen_processes" ] || \
            [ -s "$cmux_ssh_auth_signaled_groups" ] || \
            [ -s "$cmux_ssh_auth_signaled_processes" ]; then
            cmux_ssh_auth_resume_signaled_processes || return 1
          fi
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
