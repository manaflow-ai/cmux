/// Steady-state host-to-dialer throughput on one reliable channel.
public struct ThroughputResult: Codable, Sendable {
    public var recordBytes: Int
    public var priority: String
    /// Consumed by the dialer during the measurement window.
    public var receivedBytes: Int
    public var seconds: Double
    public var megabitsPerSecond: Double
    /// Process CPU (both ends, user + system) over the window.
    public var cpuSeconds: Double
    public var cpuMillisecondsPerMiB: Double
}
