/// The exact kernel-process generation associated with lifecycle evidence.
public nonisolated struct AgentProcessGeneration: Codable, Comparable, Hashable, Sendable {
    /// The numeric process identifier.
    public let pid: Int32
    /// Whole seconds in the process start timestamp.
    public let startSeconds: Int64
    /// Microseconds in the process start timestamp.
    public let startMicroseconds: Int64

    /// Creates an exact process-generation value.
    ///
    /// - Parameters:
    ///   - pid: The positive kernel process identifier.
    ///   - startSeconds: Whole seconds in the process start timestamp.
    ///   - startMicroseconds: Microseconds in the process start timestamp.
    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    /// Orders process generations chronologically, then by PID for a total order.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.startSeconds != rhs.startSeconds {
            return lhs.startSeconds < rhs.startSeconds
        }
        if lhs.startMicroseconds != rhs.startMicroseconds {
            return lhs.startMicroseconds < rhs.startMicroseconds
        }
        return lhs.pid < rhs.pid
    }
}
