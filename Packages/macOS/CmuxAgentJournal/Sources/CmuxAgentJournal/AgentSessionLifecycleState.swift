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
    /// Whether the session's last turn ended with work still outstanding (a
    /// running background task or a scheduled cron).
    ///
    /// Carried beside the phase rather than folded into it: the turn is over,
    /// which is what the pane shows, but hibernation must still not reclaim the
    /// pane out from under the outstanding work. Encoding it as `running`
    /// instead made the pane claim the agent was working when it had finished.
    public var pendingWork: Bool
    /// Whether this entry holds a whole-pane reading rather than a real agent
    /// session.
    ///
    /// A pane assertion only gets an entry of its own when there was no live
    /// session for it to correct. It is a placeholder for a pane nothing has
    /// reported on yet, so the first real session event supersedes it — without
    /// that, a pane declared errored before its agent ever spoke could never go
    /// green again.
    public var isPaneAssertion: Bool

    /// Creates a session state.
    ///
    /// - Parameters:
    ///   - phase: The session's current phase.
    ///   - ended: Whether the session has ended.
    ///   - lastSequence: Sequence of the newest applied event.
    ///   - lastOccurredAtMs: Producer timestamp of the newest applied event.
    ///   - pendingWork: Whether outstanding work survives the last turn.
    ///   - isPaneAssertion: Whether this entry holds a whole-pane reading.
    public init(
        phase: AgentLifecyclePhase,
        ended: Bool,
        lastSequence: Int64,
        lastOccurredAtMs: Int64,
        pendingWork: Bool = false,
        isPaneAssertion: Bool = false
    ) {
        self.phase = phase
        self.ended = ended
        self.lastSequence = lastSequence
        self.lastOccurredAtMs = lastOccurredAtMs
        self.pendingWork = pendingWork
        self.isPaneAssertion = isPaneAssertion
    }
}
