public import CmuxAgentReplica

/// Event payload removing one versioned session entity.
public struct GuiSessionRemovedEvent: Codable, Hashable, Sendable {
    /// The removed session identifier.
    public let sessionID: AgentSessionID
    /// The removal entity version.
    public let version: EntityVersion

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case version
    }

    /// Creates a session-removal payload.
    /// - Parameters:
    ///   - sessionID: The removed session identifier.
    ///   - version: The removal entity version.
    public init(sessionID: AgentSessionID, version: EntityVersion) {
        self.sessionID = sessionID
        self.version = version
    }
}
