/// Stable identity for one foreground process and terminal-runtime generation.
public struct AgentTerminalProcessIdentity: Sendable, Equatable, Hashable {
    /// The operating-system process identifier.
    public let pid: Int32
    /// Process start time seconds from the kernel process record.
    public let startSeconds: Int64
    /// Process start time microseconds from the kernel process record.
    public let startMicroseconds: Int64
    /// The native terminal runtime generation that observed the process.
    public let runtimeGeneration: UInt64

    /// Creates a generation-safe foreground process identity.
    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int64, runtimeGeneration: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.runtimeGeneration = runtimeGeneration
    }
}
