internal import Foundation

// The upload shell transaction is kept separate from its SSH orchestration so
// the descriptor ownership boundary is visible and executable in isolation.
extension RemoteSessionCoordinator {
    /// Builds the remote stdin upload transaction.
    ///
    /// The watchdog inherits the parent's descriptors when it is forked. It
    /// never reads the payload, so close both inherited descriptors before it
    /// can spawn `sleep`; otherwise that grandchild keeps the temporary file
    /// open after promotion and Linux returns `ETXTBSY` when hello executes it.
    static func remoteDaemonUploadScript(
        remoteTempPath: String,
        remoteTempPIDPath: String,
        expectedByteCount: Int64
    ) -> String {
        let quotedRemoteTempPath = remoteTempPath.shellSingleQuoted
        let quotedRemoteTempPIDPath = remoteTempPIDPath.shellSingleQuoted
        return """
        cat_pid=
        watchdog_pid=
        temp_path=\(quotedRemoteTempPath)
        pid_path=\(quotedRemoteTempPIDPath)
        lock_path="$pid_path.lock"
        trap 'if [ -n "$cat_pid" ]; then kill "$cat_pid" 2>/dev/null || true; fi; if [ -n "$watchdog_pid" ]; then kill "$watchdog_pid" 2>/dev/null || true; fi; rm -f -- "$temp_path" "$pid_path"; rmdir "$lock_path" 2>/dev/null || true; exit 1' HUP INT TERM
        # POSIX shells give an asynchronous command /dev/null for stdin unless
        # the parent explicitly preserves the descriptor first. Without this
        # dup, cat exits 0 after writing an empty payload even though ssh had
        # a file-backed stdin stream to forward.
        exec 3<&0
        # Keep the shell PID marker for stale-file detection. Recovery never
        # signals a marker PID because numeric PIDs can be reused.
        set -C
        # Create the owner marker atomically after noclobber is enabled.
        if ! printf '%s\\n' "$$" > "$pid_path"; then
          exit 76
        fi
        # Open the payload once with noclobber, then write through the
        # descriptor. This refuses a pre-existing payload symlink or file.
        if ! exec 4> "$temp_path"; then
          exit 76
        fi
        cat <&3 >&4 &
        cat_pid=$!
        (
          # The watchdog and its sleep child must never retain the payload
          # writer. The parent closes its own descriptor after cat exits, but
          # descendants would otherwise keep the promoted executable busy.
          exec 3<&-
          exec 4>&-
          stall_checks=0
          previous_size=0
          while kill -0 "$cat_pid" 2>/dev/null; do
            # Serialize the heartbeat with stale-file recovery. mkdir is an
            # atomic directory claim on the remote filesystem.
            if mkdir "$lock_path" 2>/dev/null; then
              if ! touch "$pid_path" 2>/dev/null; then
                rmdir "$lock_path" 2>/dev/null || true
                exit 0
              fi
              rmdir "$lock_path" 2>/dev/null || true
            fi
            current_size="$(wc -c < "$temp_path" 2>/dev/null || printf '0')"
            set -- $current_size
            current_size="${1:-0}"
            if [ "$current_size" -ge \(expectedByteCount) ]; then exit 0; fi
            if [ "$current_size" -gt "$previous_size" ]; then
              previous_size="$current_size"
              stall_checks=0
            else
              stall_checks=$((stall_checks + 1))
            fi
            if [ "$stall_checks" -ge \(Self.daemonUploadStallCheckLimit) ]; then
              # Abort silently. The local SSH result is mapped to a generic
              # user error and bounded detail is retained in debugLog.
              # without byte progress
              kill "$cat_pid" 2>/dev/null || true
              exit 0
            fi
            sleep \(Self.daemonUploadStallCheckIntervalSeconds)
          done
        ) >/dev/null 2>&1 &
        watchdog_pid=$!
        wait "$cat_pid"
        cat_status=$?
        cat_pid=
        exec 3<&-
        exec 4>&-
        if [ -n "$watchdog_pid" ]; then kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true; fi
        watchdog_pid=
        if [ "$cat_status" -ne 0 ]; then rm -f -- "$temp_path"; fi
        trap - HUP INT TERM
        exit "$cat_status"
        """
    }
}
