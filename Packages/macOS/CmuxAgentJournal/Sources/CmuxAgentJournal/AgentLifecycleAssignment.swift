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
    /// Whether outstanding background work survives the last turn. The pane
    /// shows the phase; hibernation additionally refuses a pane with pending
    /// work, so the two no longer have to share one value.
    public let pendingWork: Bool

    /// Creates an assignment.
    ///
    /// - Parameters:
    ///   - surfaceId: The surface UUID string as recorded on journal events.
    ///   - agentKey: The sidebar lifecycle status key.
    ///   - phase: The combined phase to apply, or `nil` to clear.
    ///   - pendingWork: Whether outstanding background work survives.
    public init(
        surfaceId: String,
        agentKey: String,
        phase: AgentLifecyclePhase?,
        pendingWork: Bool = false
    ) {
        self.surfaceId = surfaceId
        self.agentKey = agentKey
        self.phase = phase
        self.pendingWork = pendingWork
    }
}
