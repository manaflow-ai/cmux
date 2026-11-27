import Foundation

/// One process on one host. PIDs are only unique per machine, so a Cloud
/// machine's terminal processes never collide with local ones.
public struct ProcessKey: Hashable, Sendable, CustomStringConvertible {
    /// `local` for this Mac, else the machine id of a remote daemon.
    public var host: String
    public var pid: Int32

    public static let localHost = "local"

    public init(host: String = ProcessKey.localHost, pid: Int32) {
        self.host = host
        self.pid = pid
    }

    public var description: String { "\(host):\(pid)" }
}

/// Cumulative counters of one process at one instant. CPU is the total
/// user plus system time since the process started, so a percentage needs
/// two samples of the same process (``ResourceAggregator``).
public struct ProcessSample: Sendable, Equatable {
    public var key: ProcessKey
    public var name: String
    public var cpuNanos: UInt64
    /// Physical footprint on macOS (what Activity Monitor shows), resident
    /// memory on Linux.
    public var memoryBytes: UInt64
    /// Monotonic nanoseconds on the sampling host's clock. Two samples of
    /// the same process always come from the same host.
    public var sampledAtNanos: UInt64

    public init(key: ProcessKey, name: String, cpuNanos: UInt64, memoryBytes: UInt64, sampledAtNanos: UInt64) {
        self.key = key
        self.name = name
        self.cpuNanos = cpuNanos
        self.memoryBytes = memoryBytes
        self.sampledAtNanos = sampledAtNanos
    }
}

/// CPU and memory of a set of processes.
public struct ResourceUsage: Sendable, Equatable {
    /// Share of one core over the last interval (1.0 = 100%, can exceed 1
    /// on several cores). Nil until a second sample exists.
    public var cpu: Double?
    public var memoryBytes: UInt64

    public init(cpu: Double? = nil, memoryBytes: UInt64 = 0) {
        self.cpu = cpu
        self.memoryBytes = memoryBytes
    }

    public static let zero = ResourceUsage(cpu: nil, memoryBytes: 0)
}
