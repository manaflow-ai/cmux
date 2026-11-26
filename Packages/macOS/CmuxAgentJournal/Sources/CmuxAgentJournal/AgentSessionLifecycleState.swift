/// Reduced lifecycle state of one agent session on one surface.
public struct AgentSessionLifecycleState: Sendable, Equatable {
    /// The session's current phase.
    public var phase: AgentLifecyclePhase
    /// Whether the session has ended (ended sessions no longer contribute to
    /// the surface's combined phase).
    public var ended: Bool
    /// Sequence of the newest event applied to this session; older or
    /// duplicate events are dropped, which makes the fold deterministic under
    /// re-delivery and permutation.
    public var lastSequence: Int64
    /// Producer timestamp of the newest applied event (ms since Unix epoch).
    public var lastOccurredAtMs: Int64

    /// Creates a session state.
    ///
    /// - Parameters:
    ///   - phase: The session's current phase.
    ///   - ended: Whether the session has ended.
    ///   - lastSequence: Sequence of the newest applied event.
    ///   - lastOccurredAtMs: Producer timestamp of the newest applied event.
    public init(
        phase: AgentLifecyclePhase,
        ended: Bool,
        lastSequence: Int64,
        lastOccurredAtMs: Int64
    ) {
        self.phase = phase
        self.ended = ended
        self.lastSequence = lastSequence
        self.lastOccurredAtMs = lastOccurredAtMs
    }
}
