public import Foundation

/// One sticky agent-session → account pin from `GET /_subrouter/sessions`.
public struct SubrouterSessionAssignment: Sendable, Hashable, Codable, Identifiable {
    /// The agent kind that owns the session (e.g. `"codex"`, `"claude"`).
    public var agentType: String
    /// The agent's session identifier.
    public var sessionID: String
    /// The pinned account id (Codex email or Claude profile name).
    public var accountID: String
    /// The end-user email attached to the session, when known.
    public var userEmail: String?
    /// When the pin was created.
    public var createdAt: Date
    /// When the pin last routed a request.
    public var updatedAt: Date

    /// A stable identity for lists: agent type plus session id.
    public var id: String { "\(agentType):\(sessionID)" }

    private enum CodingKeys: String, CodingKey {
        case agentType = "agent_type"
        case sessionID = "session_id"
        case accountID = "account_id"
        case userEmail = "user_email"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Creates a session assignment.
    /// - Parameters:
    ///   - agentType: The agent kind that owns the session.
    ///   - sessionID: The agent's session identifier.
    ///   - accountID: The pinned account id.
    ///   - userEmail: The end-user email, when known.
    ///   - createdAt: When the pin was created.
    ///   - updatedAt: When the pin last routed a request.
    public init(
        agentType: String,
        sessionID: String,
        accountID: String,
        userEmail: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.agentType = agentType
        self.sessionID = sessionID
        self.accountID = accountID
        self.userEmail = userEmail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
