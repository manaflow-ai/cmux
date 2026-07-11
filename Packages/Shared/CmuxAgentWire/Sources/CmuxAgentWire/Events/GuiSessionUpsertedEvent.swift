public import CmuxAgentReplica

/// Event payload carrying one whole-value session upsert.
public struct GuiSessionUpsertedEvent: Codable, Hashable, Sendable {
    /// The upserted session snapshot.
    public let session: AgentSessionSnapshot

    /// Creates a session-upsert payload.
    /// - Parameter session: The upserted session snapshot.
    public init(session: AgentSessionSnapshot) {
        self.session = session
    }
}
