/// The complete evidence considered before an integration may settle a turn.
public nonisolated struct AgentTurnSettlementEvidence: Equatable, Sendable {
    /// The strength of the incoming turn boundary.
    public let boundary: AgentTurnBoundary
    /// The number of structured background tasks still active.
    public let activeBackgroundWorkCount: Int
    /// Liveness of the exact process generation that emitted the event.
    public let processLiveness: AgentTurnProcessLiveness
    /// Freshness of the incoming turn identifier.
    public let turnFreshness: AgentTurnFreshness

    /// Creates settlement evidence.
    ///
    /// Negative background-work counts are clamped to zero.
    ///
    /// - Parameters:
    ///   - boundary: The incoming turn boundary.
    ///   - activeBackgroundWorkCount: Structured work still active.
    ///   - processLiveness: Liveness of the emitting process generation.
    ///   - turnFreshness: Ordering of the incoming turn; defaults to unknown.
    public init(
        boundary: AgentTurnBoundary,
        activeBackgroundWorkCount: Int,
        processLiveness: AgentTurnProcessLiveness,
        turnFreshness: AgentTurnFreshness = .unknown
    ) {
        self.boundary = boundary
        self.activeBackgroundWorkCount = max(0, activeBackgroundWorkCount)
        self.processLiveness = processLiveness
        self.turnFreshness = turnFreshness
    }
}
