import Darwin

struct AgentPIDProcessIdentity: Equatable, Hashable, Sendable {
    let pid: pid_t
    let startSeconds: Int64
    let startMicroseconds: Int64

    init(pid: pid_t, startSeconds: Int64, startMicroseconds: Int64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    /// Reads a live process's birth timestamp, which distinguishes it from a
    /// later process that reused the same PID.
    ///
    /// Uses `sysctl` rather than `proc_pidinfo`, which refuses any process
    /// whose effective UID differs from ours — including the root `login` that
    /// heads every terminal's process group. `sysctl` reports the same
    /// timestamp for those, so an unreadable identity means the process is
    /// gone rather than merely privileged.
    ///
    /// `sysctl` also still describes a process that exited but has not been
    /// reaped, which `proc_pidinfo` refused. Zombies are rejected explicitly so
    /// a readable identity keeps meaning the process is running — callers such
    /// as session restore treat it as proof the agent is still alive.
    init?(pid: pid_t) {
        guard let snapshot = Self.processSnapshot(pid: pid) else { return nil }
        self = snapshot.identity
    }

    /// Reads identity and ancestry from one kernel snapshot so callers do not
    /// accidentally combine a reused pid with metadata from different process
    /// generations. Zombies are rejected just as in `init?(pid:)`.
    static func processSnapshot(
        pid: pid_t
    ) -> (identity: AgentPIDProcessIdentity, parentPID: pid_t)? {
        guard let entry = processTableEntry(pid: pid), !entry.hasExited else { return nil }
        return (
            identity: AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: entry.startSeconds,
                startMicroseconds: entry.startMicroseconds
            ),
            parentPID: entry.parentPID
        )
    }

    /// Whether the process has exited but has not yet been reaped.
    ///
    /// A zombie still holds a process-table row and still accepts signals, so
    /// `kill(pid, 0)` cannot distinguish it from a running process. It runs no
    /// code and can own no resources, so callers weighing whether a PID might
    /// still hold something read it as gone.
    static func hasExitedWithoutReaping(pid: pid_t) -> Bool {
        processTableEntry(pid: pid)?.hasExited ?? false
    }

    /// One read of the process table, shared so a second reader cannot drift
    /// into different privilege or liveness behavior.
    private static func processTableEntry(
        pid: pid_t
    ) -> (startSeconds: Int64, startMicroseconds: Int64, parentPID: pid_t, hasExited: Bool)? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else {
            return nil
        }
        let started = info.kp_proc.p_un.__p_starttime
        return (
            Int64(started.tv_sec),
            Int64(started.tv_usec),
            pid_t(info.kp_eproc.e_ppid),
            info.kp_proc.p_stat == Int8(SZOMB)
        )
    }
}
