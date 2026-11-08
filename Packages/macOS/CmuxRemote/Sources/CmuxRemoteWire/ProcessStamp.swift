// SPDX-License-Identifier: GPL-3.0-or-later
public import Darwin

/// A process instance: its pid and start time. A pid alone can be reused; the
/// pair names one process for its whole life.
public struct ProcessStamp: Sendable, Equatable, Hashable, Codable {
    public var pid: pid_t
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64

    public init(pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    /// The live process `pid`, or nil when it does not exist.
    public static func of(_ pid: pid_t) -> ProcessStamp? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStamp(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    /// Whether this exact process still runs.
    public var isAlive: Bool { Self.of(pid) == self }

    public var fields: [String: Any] {
        ["pid": Int(pid), "start_sec": Int(startSeconds), "start_usec": Int(startMicroseconds)]
    }

    public init?(fields: [String: Any]) {
        guard let pid = fields["pid"] as? Int, pid > 1, pid <= Int(Int32.max),
              let seconds = fields["start_sec"] as? Int, seconds >= 0,
              let micros = fields["start_usec"] as? Int, micros >= 0 else { return nil }
        self.init(pid: pid_t(pid), startSeconds: UInt64(seconds), startMicroseconds: UInt64(micros))
    }
}
