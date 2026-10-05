import Foundation

/// What a conversation tab shows (`conversation-tabs-v1`, plans/cmux-next/home.md 7): one
/// conversation of the `local` (daemon) or `cloud` conversation owner, or an acpmux agent session
/// (`agent-session-tabs-v1`, cmux-tui/spec/commands.md new-conversation-tab). The store never reads either
/// one's content; the app renders it from its owner. Exactly one source is set.
public struct ConversationTabRef: Sendable, Hashable, Codable {
    /// The `conv_` id, for a conversation source.
    public var conversation: String?
    /// `local` or `cloud`, for a conversation source.
    public var owner: String?
    /// The agent session, for an agent chat tab.
    public var agentSession: AgentSessionRef?

    public init(conversation: String, owner: String) {
        self.conversation = conversation
        self.owner = owner
        agentSession = nil
    }

    public init(agentSession: AgentSessionRef) {
        conversation = nil
        owner = nil
        self.agentSession = agentSession
    }

    enum CodingKeys: String, CodingKey {
        case conversation, owner
        case agentSession = "agent_session"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let session = try c.decodeIfPresent(AgentSessionRef.self, forKey: .agentSession) {
            self.init(agentSession: session)
        } else {
            self.init(conversation: try c.decode(String.self, forKey: .conversation), owner: try c.decode(String.self, forKey: .owner))
        }
    }
}

/// The acpmux session an agent chat tab shows (`agent-session-tabs-v1`).
public struct AgentSessionRef: Sendable, Hashable, Codable {
    /// `install:<id>` of the machine whose acpmux runs the session. Only that machine attaches.
    public var host: String
    /// That machine's name for display ("This chat runs on <name>"), when known.
    public var hostName: String?
    /// The acpmux session; nil for a new chat until its page starts one. The
    /// `bind-conversation-tab-session` compare-and-swap changes it.
    public var session: String?
    /// The agent the chat started with, when known.
    public var harness: String?

    public init(host: String, hostName: String? = nil, session: String? = nil, harness: String? = nil) {
        self.host = host
        self.hostName = hostName
        self.session = session
        self.harness = harness
    }

    enum CodingKeys: String, CodingKey {
        case host, session, harness
        case hostName = "host_name"
    }

    /// The `host` of this installation's install id.
    public static func host(installID: String) -> String { "install:" + installID }
}
