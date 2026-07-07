import Darwin

struct AgentPIDProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let startSeconds: Int64
    let startMicroseconds: Int64

    init(pid: pid_t, startSeconds: Int64, startMicroseconds: Int64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    init?(pid: pid_t) {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        self.init(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }
}
