/// Decision produced when a rebuilt surface asks for authoritative replay.
public enum TerminalSurfaceReplayAttemptDecision: Equatable, Sendable {
    /// No replay request should be made.
    case none
    /// A replay request should be issued for the generation and retry attempt.
    case request(generation: UInt64, attempt: Int)
    /// Replay retry budget is exhausted before another request can be made.
    case failClosed(generation: UInt64)
}
