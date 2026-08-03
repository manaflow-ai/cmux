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

    init?(pid: pid_t) {
        guard let snapshot = Self.processSnapshot(pid: pid) else { return nil }
        self = snapshot.identity
    }

    /// Reads identity and ancestry from one kernel snapshot so callers do not
    /// accidentally combine a reused pid with metadata from different process
    /// generations.
    static func processSnapshot(
        pid: pid_t
    ) -> (identity: AgentPIDProcessIdentity, parentPID: pid_t)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard
            size == expectedSize,
            pid_t(info.pbi_pid) == pid,
            info.pbi_start_tvsec > 0,
            info.pbi_start_tvusec < 1_000_000
        else {
            return nil
        }
        return (
            identity: AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: Int64(info.pbi_start_tvsec),
                startMicroseconds: Int64(info.pbi_start_tvusec)
            ),
            parentPID: pid_t(info.pbi_ppid)
        )
    }
}
