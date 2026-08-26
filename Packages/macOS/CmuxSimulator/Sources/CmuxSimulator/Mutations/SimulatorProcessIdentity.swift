import Darwin

package struct SimulatorProcessIdentity: Codable, Equatable, Sendable {
    package let pid: pid_t
    package let startSeconds: Int64
    package let startMicroseconds: Int64

    package init(
        pid: pid_t,
        startSeconds: Int64,
        startMicroseconds: Int64
    ) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    package init?(pid: pid_t) {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard size == expectedSize else { return nil }
        self.init(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }

    package var isRunning: Bool {
        SimulatorProcessIdentity(pid: pid) == self
    }

    package static var parent: SimulatorProcessIdentity? {
        SimulatorProcessIdentity(pid: getppid())
    }

    package static var current: SimulatorProcessIdentity? {
        SimulatorProcessIdentity(pid: getpid())
    }
}
