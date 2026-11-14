import Darwin
import Foundation

/// A same-user process generation, including microseconds to reject recycled PIDs.
public struct ClaudeViewerProcessIdentity: Codable, Equatable, Sendable {
    /// The process identifier.
    public let pid: Int
    /// The kernel process creation time in seconds.
    public let seconds: UInt64
    /// The microsecond portion of the creation time.
    public let microseconds: UInt64

    /// Captures a live, non-zombie process belonging to this user.
    /// - Parameter pid: The local process identifier; remote namespaces are not supported.
    public init?(pid: Int) {
        guard pid > 1, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        self.pid = pid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }

    /// Whether this exact process generation is still alive.
    public var isAlive: Bool { Self(pid: pid) == self }
}
