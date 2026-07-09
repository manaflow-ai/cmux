public import CmuxAgentReplica

/// Parameters for answering a pending ask idempotently.
public struct GuiAnswerParams: Codable, Hashable, Sendable {
    /// The session that owns the ask.
    public let sessionID: AgentSessionID
    /// The stable pending-ask identifier.
    public let askID: String
    /// The selected zero-based choice index.
    public let choiceIndex: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case askID = "ask_id"
        case choiceIndex = "choice_index"
    }

    /// Creates answer parameters.
    /// - Parameters:
    ///   - sessionID: The session that owns the ask.
    ///   - askID: The stable ask identifier.
    ///   - choiceIndex: The selected zero-based choice index.
    public init(sessionID: AgentSessionID, askID: String, choiceIndex: Int) {
        self.sessionID = sessionID
        self.askID = askID
        self.choiceIndex = choiceIndex
    }
}

/// Result reporting whether an answer was applied.
public struct GuiAnswerResult: Codable, Hashable, Sendable {
    /// Whether the ask was answered.
    public let answered: Bool

    /// Creates an answer result.
    /// - Parameter answered: Whether the ask was answered.
    public init(answered: Bool) {
        self.answered = answered
    }
}
