/// One sidebar lifecycle mutation derived from the journal: set (or clear,
/// when `phase` is `nil`) the entry for `agentKey` on `surfaceId`.
public struct AgentLifecycleAssignment: Sendable, Equatable {
    /// The surface UUID string as recorded on the journal events (pre-alias
    /// resolution).
    public let surfaceId: String
    /// The sidebar lifecycle status key.
    public let agentKey: String
    /// The combined phase to apply, or `nil` to clear the entry.
    public let phase: AgentLifecyclePhase?

    /// Creates an assignment.
    ///
    /// - Parameters:
    ///   - surfaceId: The surface UUID string as recorded on journal events.
    ///   - agentKey: The sidebar lifecycle status key.
    ///   - phase: The combined phase to apply, or `nil` to clear.
    public init(surfaceId: String, agentKey: String, phase: AgentLifecyclePhase?) {
        self.surfaceId = surfaceId
        self.agentKey = agentKey
        self.phase = phase
    }
}
