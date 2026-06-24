/// Retry state for authoritative replay after a surface rebuild.
public struct TerminalSurfaceReplayRecovery: Equatable, Sendable {
    /// Generation that must receive replay output.
    public var generation: UInt64
    /// Number of replay attempts already started.
    public var attempts: Int

    /// Creates replay retry state for a surface generation.
    public init(generation: UInt64, attempts: Int) {
        self.generation = generation
        self.attempts = attempts
    }
}
