/// What one terminal session is using, for telling the user which terminal
/// is running away.
public struct RunawaySessionUsage: Equatable, Sendable {
    /// The session's controlling tty device.
    public let ttyDevice: Int64
    /// Physical-footprint bytes of every process on the tty.
    public let memoryBytes: Int64
    /// Number of processes on the tty.
    public let processCount: Int
    /// The process that best names the runaway: the leader of the job group
    /// holding the most memory, or its largest member when the leader is gone.
    public let dominantProcessID: Int?
    /// False when memory bytes are only a lower bound and cannot prove recovery.
    public let memoryIsComplete: Bool

    /// Creates a usage value.
    public init(ttyDevice: Int64, memoryBytes: Int64, processCount: Int, dominantProcessID: Int?, memoryIsComplete: Bool = true) {
        self.ttyDevice = ttyDevice
        self.memoryBytes = memoryBytes
        self.processCount = processCount
        self.dominantProcessID = dominantProcessID
        self.memoryIsComplete = memoryIsComplete
    }
}
