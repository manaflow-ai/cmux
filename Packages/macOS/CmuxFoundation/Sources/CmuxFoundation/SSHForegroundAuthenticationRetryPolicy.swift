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
    /// The helper takes one kernel process-table snapshot, indexes parent/child
    /// edges in one pass, and freezes the reachable tree with shell-builtin
    /// signals. Each accepted record carries its PID, parent, process group, and
    /// microsecond kernel start identity.
    /// A second snapshot must confirm the identity and stopped state before the
    /// helper sends `SIGKILL`. After `SIGTERM`, the helper waits for the
    /// per-attempt completion FIFO emitted by the authentication wrapper, then
    /// records descendants that still hold the attempt's marker descriptor.
    /// Failed snapshots never trigger an unverified signal. This keeps cleanup
    /// bounded when the runner cannot fork and avoids killing a reused PID.
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
          umask 077
          cmux_ssh_auth_state_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmux-ssh-auth-tree.XXXXXX") || exit 0
          cmux_ssh_auth_snapshot="$cmux_ssh_auth_state_dir/snapshot"
          cmux_ssh_auth_members="$cmux_ssh_auth_state_dir/members"
          cmux_ssh_auth_pending="$cmux_ssh_auth_state_dir/pending"
          cmux_ssh_auth_owned="$cmux_ssh_auth_state_dir/owned"
          cmux_ssh_auth_live="$cmux_ssh_auth_state_dir/live"
          cmux_ssh_auth_term="$cmux_ssh_auth_state_dir/term"
          cmux_ssh_auth_term_candidates="$cmux_ssh_auth_state_dir/term-candidates"
          cmux_ssh_auth_stop_candidates="$cmux_ssh_auth_state_dir/stop-candidates"
          cmux_ssh_auth_kill_candidates="$cmux_ssh_auth_state_dir/kill-candidates"
          cmux_ssh_auth_root_identity_file="$cmux_ssh_auth_state_dir/root-identity"
          cmux_ssh_auth_root_identity_candidate="$cmux_ssh_auth_state_dir/root-identity-candidate"
          cmux_ssh_auth_dynamic_members="$cmux_ssh_auth_state_dir/dynamic-members"
          cmux_ssh_auth_marker_holders="$cmux_ssh_auth_state_dir/marker-holders"
          cmux_ssh_auth_root_identity=
          cmux_ssh_auth_event_token="${4:-${CMUX_SSH_AUTH_EVENT_TOKEN:-}}"
          case "$cmux_ssh_auth_event_token" in
            ''|*[!A-Za-z0-9_-]*) cmux_ssh_auth_event_token= ;;
          esac
          cmux_ssh_auth_term_event_dir=
          if [ -n "$cmux_ssh_auth_event_token" ]; then
            cmux_ssh_auth_term_event_dir="${TMPDIR:-/tmp}/cmux-ssh-auth-term.$cmux_ssh_auth_event_token"
          fi
          cmux_ssh_auth_term_event_fifo=
          cmux_ssh_auth_term_event_ack_fifo=
          cmux_ssh_auth_marker_path=
          if [ -n "$cmux_ssh_auth_event_token" ]; then
            cmux_ssh_auth_marker_path="${TMPDIR:-/tmp}/cmux-ssh-auth-marker.$cmux_ssh_auth_event_token"
            cmux_ssh_auth_term_event_fifo="$cmux_ssh_auth_term_event_dir/done"
            cmux_ssh_auth_term_event_ack_fifo="$cmux_ssh_auth_term_event_dir/ack"
          fi
          cmux_ssh_auth_term_event_owned=0
          cmux_ssh_auth_term_event_received=0
          : > "$cmux_ssh_auth_owned" || exit 0
          : > "$cmux_ssh_auth_pending" || exit 0
          : > "$cmux_ssh_auth_dynamic_members" || exit 0
          : > "$cmux_ssh_auth_marker_holders" || exit 0

          cmux_ssh_auth_take_snapshot() {
            # `ps lstart` is only second-resolution. Read proc_bsdinfo directly
            # so every snapshot carries the kernel birth timestamp instead of a
            # value that can collide after rapid PID reuse. One Perl process
            # walks the PID list, which keeps this path viable under fork
            # pressure and avoids one child process per candidate.
            /usr/bin/perl -e '
              use strict;
              use warnings;
              my $max_pid_count = 65536;
              my $pid_buffer = "\0" x (4 * $max_pid_count);
              my $pid_bytes = syscall(336, 1, 1, 0, 0, $pid_buffer, length($pid_buffer));
              exit 1 unless defined($pid_bytes) && $pid_bytes >= 0 &&
                $pid_bytes < length($pid_buffer) && ($pid_bytes % 4) == 0;
              my %state = (1 => "I", 2 => "R", 3 => "S", 4 => "T", 5 => "Z");
              for (my $offset = 0; $offset < $pid_bytes; $offset += 4) {
                my $pid = unpack("L<", substr($pid_buffer, $offset, 4));
                next unless $pid > 0;
                my $info_buffer = "\0" x 184;
                my $info_size = syscall(336, 2, $pid, 3, 0, $info_buffer, length($info_buffer));
                my ($group_offset, $seconds_offset, $microseconds_offset);
                if ($info_size == 136) {
                  $group_offset = 100;
                  $seconds_offset = 120;
                  $microseconds_offset = 128;
                } elsif ($info_size == 184) {
                  $group_offset = 148;
                  $seconds_offset = 168;
                  $microseconds_offset = 176;
                } else {
                  next;
                }
                my $status = unpack("L<", substr($info_buffer, 4, 4));
                my $observed_pid = unpack("L<", substr($info_buffer, 12, 4));
                my $parent = unpack("L<", substr($info_buffer, 16, 4));
                my $group = unpack("L<", substr($info_buffer, $group_offset, 4));
                my $seconds = unpack("Q<", substr($info_buffer, $seconds_offset, 8));
                my $microseconds = unpack("Q<", substr($info_buffer, $microseconds_offset, 8));
                next unless $observed_pid == $pid && $group > 0 && $seconds > 0 &&
                  $microseconds < 1_000_000;
                next unless exists $state{$status};
                print "$pid $parent $group $state{$status} K $seconds $microseconds 0 0\n";
              }
            ' > "$cmux_ssh_auth_snapshot" 2>/dev/null
          }

          cmux_ssh_auth_extract_tree() {
            : > "$cmux_ssh_auth_members"
            : > "$cmux_ssh_auth_root_identity_candidate"
            /usr/bin/awk \
              -v cmux_root="$cmux_ssh_auth_tree_root_pid" \
              -v cmux_root_parent="$cmux_ssh_auth_tree_root_parent" \
              -v cmux_root_identity_candidate="$cmux_ssh_auth_root_identity_candidate" '
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
          }

          cmux_ssh_auth_append_pending() {
            while IFS= read -r cmux_ssh_auth_pending_line; do
              [ -n "$cmux_ssh_auth_pending_line" ] || continue
              printf '%s\n' "$cmux_ssh_auth_pending_line" >> "$cmux_ssh_auth_owned" || return 1
            done < "$cmux_ssh_auth_pending"
            : > "$cmux_ssh_auth_pending" || return 1
          }

          # A TERM handler can create a new session, exit, and leave its
          # replacement reparented before the next process-table snapshot. The
          # classifier therefore keeps a per-attempt marker FD open. `lsof`
          # returns the exact processes that inherited that FD, including a
          # detached replacement. Record their PID, parent, PGID, and kernel
          # start identity, then follow only their current descendants. A random
          # marker token and the inherited descriptor are the ownership proof;
          # no numeric process-group reuse can authorize an unrelated process.
          cmux_ssh_auth_record_dynamic_members() {
            cmux_ssh_auth_take_snapshot || return 1
            : > "$cmux_ssh_auth_marker_holders" || return 1
            if [ -n "$cmux_ssh_auth_marker_path" ] && [ -f "$cmux_ssh_auth_marker_path" ]; then
              /usr/sbin/lsof -n -w -t -- "$cmux_ssh_auth_marker_path" \
                > "$cmux_ssh_auth_marker_holders" 2>/dev/null || : > "$cmux_ssh_auth_marker_holders"
            fi
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                # PPID is lineage metadata and can change when a TERM handler
                # outlives its parent. PID, PGID, and the kernel birth token
                # remain the stable identity fence.
                cmux_original_identity[$2 SUBSEP $4 SUBSEP $6] = 1
                next
              }
              FILENAME == ARGV[2] {
                if ($1 ~ /^[0-9]+$/) cmux_marker[$1] = 1
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
                # Marker holders are the roots of the post-TERM lineage. The
                # child walk remains identity-anchored to this one snapshot.
                for (cmux_pid in cmux_marker) {
                  if (cmux_pid in cmux_process && cmux_state[cmux_pid] !~ /Z/) {
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
                for (cmux_pid in cmux_lineage) {
                  cmux_started_id = cmux_started[cmux_pid]
                  if (cmux_state[cmux_pid] !~ /Z/ &&
                      !((cmux_pid SUBSEP cmux_group[cmux_pid] SUBSEP cmux_started_id) in cmux_original_identity)) {
                    print cmux_pid, cmux_parent[cmux_pid], cmux_group[cmux_pid], cmux_started_id
                  }
                }
              }
            ' "$cmux_ssh_auth_members" "$cmux_ssh_auth_marker_holders" \
              "$cmux_ssh_auth_snapshot" >> "$cmux_ssh_auth_dynamic_members"
          }

          # The generated authentication wrapper publishes the nonce only after
          # its TERM handler has waited for the command to finish. It then waits
          # for the helper ACK before exiting. This gives the helper a
          # happens-before edge for handler-created replacements while keeping
          # the wrapper alive during the post-TERM process-table snapshot. A
          # bounded read keeps plain fixtures and failed wrappers from blocking
          # cleanup.
          cmux_ssh_auth_wait_for_term_event() {
            [ "$cmux_ssh_auth_wait_for_term_event_enabled" = 1 ] || return 0
            [ -n "$cmux_ssh_auth_event_token" ] || return 0
            if [ ! -p "$cmux_ssh_auth_term_event_fifo" ]; then return 0; fi
            if [ ! -p "$cmux_ssh_auth_term_event_ack_fifo" ] || ! exec 10<> "$cmux_ssh_auth_term_event_ack_fifo"; then return 0; fi
            exec 9<> "$cmux_ssh_auth_term_event_fifo" || return 0
            cmux_ssh_auth_term_event_writer=
            # macOS /bin/sh accepts only an integer read timeout. Start this
            # bounded grace after TERM so scheduler pressure can delay the
            # handler without blocking cleanup forever. The FIFO stays open
            # across retries.
            cmux_ssh_auth_term_event_wait_start=${SECONDS:-0}
            while [ "$cmux_ssh_auth_term_event_received" != 1 ] &&
                  [ "$((${SECONDS:-0} - cmux_ssh_auth_term_event_wait_start))" -lt 5 ]; do
              if IFS= read -r -t 1 cmux_ssh_auth_term_event_writer <&9; then
                # The FIFO directory and payload both carry the random,
                # per-attempt nonce. Process ownership is established by the
                # marker FD journal, not by a PID that can be reused.
                if [ "$cmux_ssh_auth_term_event_writer" = "$cmux_ssh_auth_event_token" ]; then
                  cmux_ssh_auth_term_event_received=1
                fi
              fi
            done
            if [ "$cmux_ssh_auth_term_event_received" != 1 ]; then
              exec 9>&-
            fi
          }

          cmux_ssh_auth_ack_term_event() {
            if [ "$cmux_ssh_auth_term_event_received" = 1 ]; then
              printf '%s\n' "$cmux_ssh_auth_event_token" >&10 2>/dev/null || true
            fi
            exec 9>&-
          }

          # Validate and signal an identity batch with macOS's audit-token
          # process API. The shell/awk snapshot is only a candidate list. The
          # audit token carries the kernel PID version, so the kernel rejects a
          # signal after PID reuse instead of applying it to the new process.
          # STOP candidates are checked again after the signal and only a
          # confirmed stop enters the ownership journal. TERM and KILL are sent
          # only to a confirmed stopped identity. A stopped process cannot exit
          # and reuse its PID, which also closes the destructive KILL window.
          cmux_ssh_auth_signal_verified_batch() {
            cmux_ssh_auth_signal_name="$1"
            cmux_ssh_auth_signal_input="$2"
            cmux_ssh_auth_signal_output="${3:-/dev/null}"
            /usr/bin/ruby -rfiddle -rfiddle/import -e '
              signal_name, input_path, output_path = ARGV
              signals = { "STOP" => 17, "TERM" => 15, "CONT" => 19, "KILL" => 9 }
              exit 2 unless signals.key?(signal_name) && input_path && output_path

              module CmuxLibproc
                extend Fiddle::Importer
                dlload "/usr/lib/libproc.dylib"
                extern "int proc_pidinfo(int, int, unsigned long long, void*, int)"
                extern "int proc_signal_with_audittoken(void*, int)"
              end

              bsd_with_unique_id_flavor = 18
              process_info_size = 192
              uint32 = ->(bytes, offset) { bytes.byteslice(offset, 4).unpack1("L<") }
              uint64 = ->(bytes, offset) { bytes.byteslice(offset, 8).unpack1("Q<") }
              process_identity = lambda do |pid|
                buffer = Fiddle::Pointer.malloc(process_info_size)
                written = CmuxLibproc.proc_pidinfo(
                  Integer(pid), bsd_with_unique_id_flavor, 0, buffer, process_info_size
                )
                next nil unless written == process_info_size
                bytes = buffer.to_s(process_info_size)
                [
                  uint32.call(bytes, 12), # pbi_pid
                  uint32.call(bytes, 16), # pbi_ppid
                  uint32.call(bytes, 100), # pbi_pgid
                  uint32.call(bytes, 4), # pbi_status
                  uint64.call(bytes, 120), # pbi_start_tvsec
                  uint64.call(bytes, 128), # pbi_start_tvusec
                  uint32.call(bytes, 168), # proc_uniqueidentifierinfo.id_version
                ]
              rescue ArgumentError, Fiddle::DLError, NoMethodError, RangeError, TypeError
                nil
              end
              same_identity = lambda do |identity, pid, group, seconds, microseconds|
                identity && identity.length == 7 && identity[0] == pid &&
                  identity[2] == group && identity[4] == seconds && identity[5] == microseconds
              end
              signal_exact = lambda do |identity, signal_number|
                token = Fiddle::Pointer.malloc(32)
                token[0, 32] = ([0xffffffff] * 8).pack("L<*")
                token[20, 4] = [identity[0]].pack("L<")
                token[28, 4] = [identity[6]].pack("L<")
                CmuxLibproc.proc_signal_with_audittoken(token, signal_number) == 0
              end

              begin
                input = File.open(input_path, "r")
                output = File.open(output_path, "w")
                input.each_line do |line|
                fields = line.split
                next unless fields.length == 6
                depth, pid_text, parent_text, group_text, original_state, started = fields
                next unless depth.match?(/\A[0-9]+\z/) && pid_text.match?(/\A[1-9][0-9]*\z/) &&
                  parent_text.match?(/\A[0-9]+\z/) && group_text.match?(/\A[1-9][0-9]*\z/)
                match = started.match(/\AK_([0-9]+)_([0-9]+)_0_0\z/)
                next unless match
                expected_seconds = Integer(match[1])
                expected_microseconds = Integer(match[2])
                next if expected_microseconds >= 1_000_000
                pid = Integer(pid_text)
                group = Integer(group_text)
                before = process_identity.call(pid)
                next unless same_identity.call(before, pid, group, expected_seconds, expected_microseconds)
                next if before[3] == 5

                if signal_name == "STOP"
                  # Do not claim a process that was already stopped by another
                  # owner. Resuming it would be an observable side effect.
                  next if before[3] == 4
                  next unless signal_exact.call(before, signals[signal_name])
                  after = process_identity.call(pid)
                  if same_identity.call(after, pid, group, expected_seconds, expected_microseconds) &&
                      after[3] == 4
                    output.puts(line.chomp)
                  else
                    # A PID-reuse candidate may be briefly stopped. Resume it
                    # only while the same replacement identity is still stopped.
                    replacement = process_identity.call(pid)
                    if replacement && replacement[3] == 4 &&
                        !same_identity.call(replacement, pid, group, expected_seconds, expected_microseconds)
                      signal_exact.call(replacement, signals["CONT"])
                    end
                  end
                  next
                end

                # Rollback never resumes a process that was already stopped
                # before this helper acquired it.
                next if signal_name == "CONT" && original_state == "T"
                next unless before[3] == 4
                if signal_name == "TERM"
                  unless signal_exact.call(before, signals[signal_name])
                    current = process_identity.call(pid)
                    signal_exact.call(current, signals["CONT"]) if same_identity.call(
                      current, pid, group, expected_seconds, expected_microseconds
                    ) && current[3] == 4
                    next
                  end
                  after = process_identity.call(pid)
                  signal_exact.call(after, signals["CONT"]) if same_identity.call(
                    after, pid, group, expected_seconds, expected_microseconds
                  ) && after[3] == 4
                else
                  signal_exact.call(before, signals[signal_name])
                end
                end
              ensure
                input&.close
                output&.close
              end
          ' "$cmux_ssh_auth_signal_name" "$cmux_ssh_auth_signal_input" \
              "$cmux_ssh_auth_signal_output" >/dev/null 2>&1
          }

          cmux_ssh_auth_resume_kernel_journal() {
            cmux_ssh_auth_signal_verified_batch CONT "$1" /dev/null || true
          }

          cmux_ssh_auth_resume_unconfirmed_stops() {
            cmux_ssh_auth_resume_path="$1"
            [ -s "$cmux_ssh_auth_resume_path" ] || return 0
            cmux_ssh_auth_resume_kernel_journal "$cmux_ssh_auth_resume_path"
          }

          # Re-read the process table once immediately before each signal
          # batch. Every row carries PID, PPID, PGID, and a kernel-start token.
          # The stable key uses PID, PGID, and that token because PPID changes
          # during expected reparenting. Root validation and child edges still
          # require the recorded PPID, so PID reuse cannot authorize a signal.
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
            cmux_ssh_auth_resume_kernel_journal "$cmux_ssh_auth_resume_path"
          }

          cmux_ssh_auth_cleanup() {
            trap - EXIT HUP INT TERM
            if [ "$cmux_ssh_auth_cleanup_complete" != 1 ]; then
              cmux_ssh_auth_resume_file "$cmux_ssh_auth_pending"
              cmux_ssh_auth_resume_file "$cmux_ssh_auth_owned"
            fi
            # Once the wrapper opens the per-attempt event FIFOs, marker
            # cleanup is handed to this helper. The wrapper may time out while
            # waiting for the ACK, but the marker must stay linked until every
            # post-TERM discovery pass has finished so `lsof` can still prove
            # ownership of a detached replacement.
            if [ "$cmux_ssh_auth_term_event_owned" = 1 ] && [ -n "$cmux_ssh_auth_marker_path" ]; then
              /bin/rm -f -- "$cmux_ssh_auth_marker_path" 2>/dev/null || true
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
              "$cmux_ssh_auth_pending" "$cmux_ssh_auth_owned" \
              "$cmux_ssh_auth_live" "$cmux_ssh_auth_term" \
              "$cmux_ssh_auth_term_candidates" "$cmux_ssh_auth_stop_candidates" \
              "$cmux_ssh_auth_kill_candidates" \
              "$cmux_ssh_auth_root_identity_file" "$cmux_ssh_auth_root_identity_candidate" \
              "$cmux_ssh_auth_dynamic_members" "$cmux_ssh_auth_marker_holders" \
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
          # The authentication wrapper derives this same path from the fresh
          # per-attempt nonce. A pre-existing path is never removed or reused,
          # so a stale process cannot receive an event from this attempt.
          if [ "$cmux_ssh_auth_wait_for_term_event_enabled" = 1 ] &&
             [ -n "$cmux_ssh_auth_event_token" ] &&
             /bin/mkdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null; then
            if /usr/bin/mkfifo "$cmux_ssh_auth_term_event_fifo" 2>/dev/null && \
               /usr/bin/mkfifo "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null; then
              cmux_ssh_auth_term_event_owned=1
            else
              exec 9>&- 2>/dev/null || true
              exec 10>&- 2>/dev/null || true
              # The directory was created by this invocation. Remove only its
              # own partial setup. A mkdir collision never reaches this path,
              # so a stale attempt's FIFOs remain untouched.
              /bin/rm -f "$cmux_ssh_auth_term_event_fifo" "$cmux_ssh_auth_term_event_ack_fifo" 2>/dev/null || true
              /bin/rmdir "$cmux_ssh_auth_term_event_dir" 2>/dev/null || true
              cmux_ssh_auth_term_event_fifo=
              cmux_ssh_auth_term_event_ack_fifo=
            fi
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
            # Only STOP operations that pass the in-process identity fence
            # enter the pending ownership journal.
            cmux_ssh_auth_signal_verified_batch STOP \
              "$cmux_ssh_auth_stop_candidates" "$cmux_ssh_auth_pending" || exit 0
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
          cmux_ssh_auth_signal_verified_batch TERM "$cmux_ssh_auth_term" /dev/null || true
          # The wrapper sends its event immediately after forwarding TERM and
          # waits for our ACK. Snapshot before ACK so a replacement is still
          # attached to the live wrapper even when its direct parent exits.
          cmux_ssh_auth_wait_for_term_event
          cmux_ssh_auth_record_dynamic_members || true
          # Refresh once more before releasing the wrapper. The marker-FD
          # identity journal remains valid after reparenting.
          cmux_ssh_auth_record_dynamic_members || true
          cmux_ssh_auth_ack_term_event

          # Rebuild ownership from exact identities and descendants. Marker-FD
          # identities catch a replacement that outlives its parent without
          # broadening ownership to unrelated process-group members.
          cmux_ssh_auth_extract_owned() {
            : > "$cmux_ssh_auth_live"
            /usr/bin/awk '
              FILENAME == ARGV[1] {
                cmux_owned_identity[$2 SUBSEP $4 SUBSEP $6] = 1
                next
              }
              FILENAME == ARGV[2] {
                if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ &&
                    $3 ~ /^[0-9]+$/ && $4 != "") {
                  cmux_dynamic_identity[$1 SUBSEP $3 SUBSEP $4] = 1
                }
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
                cmux_identity_key = cmux_pid SUBSEP $3 SUBSEP cmux_started[cmux_pid]
                if (cmux_identity_key in cmux_owned_identity ||
                    cmux_identity_key in cmux_dynamic_identity) {
                  cmux_seen[cmux_pid] = 1
                  cmux_queue[++cmux_queue_tail] = cmux_pid
                  cmux_depth[cmux_pid] = 0
                }
              }
              END {
                # Ownership is identity-based only. Do not expand a process
                # group by numeric PGID: the ID can be reused, and an
                # unrelated same-session member must never enter a signal
                # batch. Dynamic replacements are seeded by their marker-FD
                # identity and then followed through current child edges.
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
            ' "$cmux_ssh_auth_owned" "$cmux_ssh_auth_dynamic_members" \
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
            cmux_ssh_auth_signal_verified_batch STOP \
              "$cmux_ssh_auth_stop_candidates" "$cmux_ssh_auth_pending" || exit 0
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
          cmux_ssh_auth_signal_verified_batch KILL \
            "$cmux_ssh_auth_kill_candidates" /dev/null || cmux_ssh_auth_kill_failed=1
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
        // `script` closes descriptors inherited from its launcher. Reopen the
        // per-attempt marker in the shell it starts, before replacing that
        // shell with the authentication command, so detached descendants keep
        // the ownership capability.
        let markerBootstrap = """
        if [ -n "${CMUX_SSH_AUTH_EVENT_TOKEN:-}" ]; then
          case "$CMUX_SSH_AUTH_EVENT_TOKEN" in
            ''|*[!A-Za-z0-9_-]*) ;;
            *)
              cmux_ssh_auth_marker_path="${TMPDIR:-/tmp}/cmux-ssh-auth-marker.$CMUX_SSH_AUTH_EVENT_TOKEN"
              if [ -f "$cmux_ssh_auth_marker_path" ]; then
                # zsh's managed descriptors are close-on-exec. Use a fixed
                # descriptor so the marker survives the nested env/zsh exec.
                exec 7<> "$cmux_ssh_auth_marker_path" 2>/dev/null || true
              fi
              ;;
          esac
        fi
        exec /usr/bin/env LC_ALL=C LANG=C /bin/zsh -fc \(shellQuote(command))
        """
        let nestedCommand = "/bin/zsh -fc \(shellQuote(markerBootstrap))"
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
            // The retry supervisor allocates a fresh nonce before launching
            // this classifier. It is shared with the cleanup helper through
            // the parent environment, so nested shells never derive an event
            // path from their unrelated `$$` values.
            "cmux_ssh_auth_event_token=\"${CMUX_SSH_AUTH_EVENT_TOKEN:-}\"",
            "case \"$cmux_ssh_auth_event_token\" in ''|*[!A-Za-z0-9_-]*) cmux_ssh_auth_event_token= ;; esac",
            "cmux_ssh_auth_term_event_fifo=; cmux_ssh_auth_term_event_ack_fifo=; cmux_ssh_auth_marker_path=; cmux_ssh_auth_marker_owned=0; cmux_ssh_auth_marker_cleanup_deferred=0",
            "if [ -n \"$cmux_ssh_auth_event_token\" ]; then cmux_ssh_auth_term_event_fifo=\"${TMPDIR:-/tmp}/cmux-ssh-auth-term.$cmux_ssh_auth_event_token/done\"; cmux_ssh_auth_term_event_ack_fifo=\"${TMPDIR:-/tmp}/cmux-ssh-auth-term.$cmux_ssh_auth_event_token/ack\"; cmux_ssh_auth_marker_path=\"${TMPDIR:-/tmp}/cmux-ssh-auth-marker.$cmux_ssh_auth_event_token\"; if ( set -C; : > \"$cmux_ssh_auth_marker_path\" ) 2>/dev/null; then if exec 7<> \"$cmux_ssh_auth_marker_path\" 2>/dev/null; then cmux_ssh_auth_marker_owned=1; else /bin/rm -f -- \"$cmux_ssh_auth_marker_path\" 2>/dev/null || true; fi; fi; fi",
            // Open both FIFO endpoints before waiting for the command. The
            // helper can then enter a bounded read without blocking on FIFO
            // setup, while the completion payload still has a happens-before
            // edge after the TERM handler exits.
            "cmux_ssh_auth_completion_event_fd=",
            "cmux_ssh_auth_completion_ack_fd=",
            "cmux_ssh_auth_completion_fds_open=0",
            "cmux_ssh_auth_prepare_signal_completion() { cmux_ssh_auth_completion_fds_open=0; if [ -n \"$cmux_ssh_auth_event_token\" ] && [ -p \"$cmux_ssh_auth_term_event_fifo\" ] && [ -p \"$cmux_ssh_auth_term_event_ack_fifo\" ] && exec {cmux_ssh_auth_completion_event_fd}<> \"$cmux_ssh_auth_term_event_fifo\" 2>/dev/null && exec {cmux_ssh_auth_completion_ack_fd}<> \"$cmux_ssh_auth_term_event_ack_fifo\" 2>/dev/null; then cmux_ssh_auth_completion_fds_open=1; else exec {cmux_ssh_auth_completion_event_fd}>&- 2>/dev/null || true; exec {cmux_ssh_auth_completion_ack_fd}>&- 2>/dev/null || true; cmux_ssh_auth_completion_event_fd=; cmux_ssh_auth_completion_ack_fd=; fi; }",
            "cmux_ssh_auth_signal_completion() { if [ \"$cmux_ssh_auth_completion_fds_open\" = 1 ]; then cmux_ssh_auth_marker_cleanup_deferred=1; printf '%s\\n' \"$cmux_ssh_auth_event_token\" >&$cmux_ssh_auth_completion_event_fd 2>/dev/null || true; cmux_ssh_auth_completion_ack=; IFS= read -r -t 2 cmux_ssh_auth_completion_ack <&$cmux_ssh_auth_completion_ack_fd || true; fi; if [ -n \"${cmux_ssh_auth_completion_event_fd:-}\" ]; then exec {cmux_ssh_auth_completion_event_fd}>&- 2>/dev/null || true; fi; if [ -n \"${cmux_ssh_auth_completion_ack_fd:-}\" ]; then exec {cmux_ssh_auth_completion_ack_fd}>&- 2>/dev/null || true; fi; cmux_ssh_auth_completion_event_fd=; cmux_ssh_auth_completion_ack_fd=; cmux_ssh_auth_completion_fds_open=0; }",
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
            "  if [ \"${cmux_ssh_auth_marker_owned:-0}\" = 1 ]; then exec 7>&-; if [ \"${cmux_ssh_auth_marker_cleanup_deferred:-0}\" != 1 ]; then /bin/rm -f -- \"$cmux_ssh_auth_marker_path\" 2>/dev/null || true; fi; cmux_ssh_auth_marker_owned=0; fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_classifier_fifo\" \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_capture_signal_exit() {",
            "  cmux_ssh_auth_capture_signal_status=\"$1\"",
            "  cmux_ssh_auth_capture_signal_name=\"$2\"",
            "  trap - EXIT HUP INT TERM",
            "  if [ -n \"${cmux_ssh_auth_command_pid:-}\" ]; then",
            "    /bin/kill -\"$cmux_ssh_auth_capture_signal_name\" \"$cmux_ssh_auth_command_pid\" >/dev/null 2>&1 || true",
            "    cmux_ssh_auth_prepare_signal_completion",
            "    wait \"$cmux_ssh_auth_command_pid\" 2>/dev/null || true",
            "    cmux_ssh_auth_command_pid=",
            "    cmux_ssh_auth_signal_completion",
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
            // In event mode the helper must keep `script` alive until the
            // nested TERM handler publishes its completion marker. Ignore
            // only the helper's HUP/TERM signals in that mode; ordinary
            // wrappers retain their normal signal behavior.
            "( exec {cmux_ssh_auth_classifier_guard_fd}>&-; if [ -n \"$cmux_ssh_auth_event_token\" ]; then trap '' HUP TERM; fi; exec /usr/bin/script -q -F \"$cmux_ssh_auth_classifier_fifo\" \(nestedCommand) <&0 >&2 ) &",
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
