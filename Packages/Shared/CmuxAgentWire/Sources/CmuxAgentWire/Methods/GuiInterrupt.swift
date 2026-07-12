public import CmuxAgentReplica

/// Parameters for interrupting an agent session.
public struct GuiInterruptParams: Codable, Hashable, Sendable {
    /// The session to interrupt.
    public let sessionID: AgentSessionID
    /// Whether the server should request a hard interrupt.
    public let hard: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hard
    }

    /// Creates interrupt parameters.
    /// - Parameters:
    ///   - sessionID: The session to interrupt.
    ///   - hard: Whether to request a hard interrupt.
    public init(sessionID: AgentSessionID, hard: Bool) {
        self.sessionID = sessionID
        self.hard = hard
    }
}

/// Result reporting whether an interrupt was applied.
public struct GuiInterruptResult: Codable, Hashable, Sendable {
    /// Whether the session was interrupted.
    public let interrupted: Bool

    /// Creates an interrupt result.
    /// - Parameter interrupted: Whether the session was interrupted.
    public init(interrupted: Bool) {
        self.interrupted = interrupted
    }
}
