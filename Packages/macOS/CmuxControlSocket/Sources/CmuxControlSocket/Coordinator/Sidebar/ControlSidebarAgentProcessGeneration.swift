/// Exact kernel-process generation attached to an agent lifecycle mutation.
///
/// A numeric PID alone is not an identity because the kernel may recycle it.
/// The start timestamp lets the app reject a delayed hook from an older agent
/// after a replacement process has claimed the same panel.
public nonisolated struct ControlSidebarAgentProcessGeneration: Equatable, Sendable {
    /// The positive numeric process identifier.
    public let pid: Int32
    /// Whole seconds in the process start timestamp.
    public let startSeconds: Int64
    /// Microseconds in the process start timestamp.
    public let startMicroseconds: Int64

    /// Creates an exact process-generation value received over the socket.
    ///
    /// - Parameters:
    ///   - pid: The positive numeric process identifier.
    ///   - startSeconds: Whole seconds in the process start timestamp.
    ///   - startMicroseconds: Microseconds in the process start timestamp.
    public init(
        pid: Int32,
        startSeconds: Int64,
        startMicroseconds: Int64
    ) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}
