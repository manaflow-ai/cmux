import Foundation

/// Home on the workspace store (plans/cmux-next/home.md 7): the one home
/// workspace (`workspace-kind-v1`). Conversation tabs: `NewConversationTabRequest`.
public struct HomeWorkspaceClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// `workspace.ensure_home` result value.
    public struct EnsuredHome: Decodable, Sendable, Equatable {
        public var workspaceID: ResourceID
        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    }

    /// The store's home workspace, created on the first call and the same
    /// workspace on every later one (any key replays it). Requires `workspace-kind-v1`.
    public func ensureHome() async throws -> ResourceID {
        let key = "cmux-next-home-" + UUID().uuidString.lowercased()
        let result = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "workspace.ensure_home", params: [:], idempotencyKey: key)
        }, as: ResourceMutationResult<EnsuredHome>.self)
        return result.value.workspaceID
    }
}

/// A tab that shows `conversation` of the `owner` conversation owner
/// (`conversation-tabs-v1`), an acpmux agent session (`agentSession`,
/// `agent-session-tabs-v1`), or one of the app's own pages (`page`,
/// `page-tabs-v1`). With `origin` and `mutationID` a retry returns
/// the first tab (`replayed`).
public struct NewConversationTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var tabResourceID: ResourceID?
        public var replayed: Bool
        enum CodingKeys: String, CodingKey {
            case surface, replayed
            case tabResourceID = "tab_resource_id"
        }
    }
    public static let command = "new-conversation-tab"
    public static let requiredCapability: String? = DaemonCapabilities.shared.conversationTabs
    public var conversation: String?
    public var owner: String?
    public var agentSession: AgentSessionRef?
    public var page: String?
    public var pane: PaneID?
    /// Exclusive with `pane`: the workspace's active pane, or its first pane
    /// when it is empty (the home workspace starts empty).
    public var workspace: WorkspaceHandle?
    public var origin: String?
    public var mutationID: String?
    /// Echoed on the event that adds the tab (`conversation-tab-transaction-v1`), so a create
    /// intent settles on whichever arrives first, that event or the reply.
    public var transaction: ClientTransactionID?

    public init(conversation: String, owner: String = "local", pane: PaneID? = nil, workspace: WorkspaceHandle? = nil,
                origin: String? = nil, mutationID: String? = nil) {
        self.conversation = conversation
        self.owner = owner
        self.pane = pane
        self.workspace = workspace
        self.origin = origin
        self.mutationID = mutationID
    }

    /// An agent chat tab in `pane` on `agentSession` (`agent-session-tabs-v1`).
    public init(agentSession: AgentSessionRef, pane: PaneID, origin: String? = nil, mutationID: String? = nil,
                transaction: ClientTransactionID? = nil) {
        self.agentSession = agentSession
        self.pane = pane
        self.origin = origin
        self.mutationID = mutationID
        self.transaction = transaction
    }

    /// A page tab in `pane` showing `page` (`page-tabs-v1`).
    public init(page: String, pane: PaneID, origin: String? = nil, mutationID: String? = nil,
                transaction: ClientTransactionID? = nil) {
        self.page = page
        self.pane = pane
        self.origin = origin
        self.mutationID = mutationID
        self.transaction = transaction
    }

    /// The first agent tab creates the workspace's first pane without a shell.
    public init(agentSession: AgentSessionRef, workspace: WorkspaceHandle, origin: String? = nil, mutationID: String? = nil) {
        self.agentSession = agentSession
        self.workspace = workspace
        self.origin = origin
        self.mutationID = mutationID
    }

    enum CodingKeys: String, CodingKey {
        case conversation, owner, page, pane, workspace, origin, transaction
        case agentSession = "agent_session"
        case mutationID = "mutation_id"
    }
}

/// Sets the acpmux session of an agent chat tab by compare-and-swap (`agent-session-tabs-v1`):
/// it applies only while the tab shows `expectedSession` (nil: no session yet). The same session
/// again replays; a tab whose session changed elsewhere refuses it with
/// `conversation_tab.session_conflict:` and its current session.
public struct BindConversationTabSessionRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var replayed: Bool
    }
    public static let command = "bind-conversation-tab-session"
    public var surface: SurfaceID
    public var session: String
    public var expectedSession: String?

    public init(surface: SurfaceID, session: String, expectedSession: String? = nil) {
        self.surface = surface
        self.session = session
        self.expectedSession = expectedSession
    }

    enum CodingKeys: String, CodingKey {
        case surface, session
        case expectedSession = "expected_session"
    }

    /// `expected_session` is always sent: null is the expectation "no session yet".
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        try c.encode(session, forKey: .session)
        try c.encode(expectedSession, forKey: .expectedSession)
    }

    /// The refusal prefix of a compare-and-swap that found another session.
    public static let conflictPrefix = "conversation_tab.session_conflict"
}
