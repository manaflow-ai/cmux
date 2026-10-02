import Foundation

// `local-conversations-v1` records (plans/cmux-next/home.md section 2). The
// local conversation owner in the daemon writes them; the app only mirrors them.

/// A member of a conversation: the Mac's user, a person, or an agent (a mux or
/// an ordinary agent).
public struct ConversationParticipant: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case human, agent }

    /// `user_local`, `user_<id>` or `agent_<name>`.
    public var id: String
    public var kind: Kind
    public var displayName: String
    /// `mux` or `agent`; set only for agents.
    public var agentClass: String?
    /// The acpmux session that runs the agent, when it has one.
    public var acpSession: String?

    public init(id: String, kind: Kind, displayName: String, agentClass: String? = nil, acpSession: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.agentClass = agentClass
        self.acpSession = acpSession
    }

    /// The participant id of the Mac's own user in local conversations.
    public static let localUserID = "user_local"

    enum CodingKeys: String, CodingKey {
        case id, kind
        case displayName = "display_name"
        case agentClass = "agent_class"
        case acpSession = "acp_session"
    }
}

/// One part of a root message that a reply points at.
public struct ConversationPartRef: Codable, Sendable, Hashable {
    public var messageID: String
    public var partIndex: Int

    public init(messageID: String, partIndex: Int) {
        self.messageID = messageID
        self.partIndex = partIndex
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case partIndex = "part_index"
    }
}
