public import CmuxNextAgentActivity

/// One agent chat a live preview card can show in (``ComputerUsePreviewRoute``).
public nonisolated struct ComputerUsePreviewChat: Equatable, Sendable {
    /// The chat's tab key.
    public var key: String
    /// The acpmux session the tab shows; nil for a New Tab page.
    public var session: String?
    /// The harness's own session id (the lane's chat key without its family), when known.
    public var agentSession: String?
    public var workspaceID: String?
    /// The harness acpmux runs (`claude`, `codex`, ...), when known.
    public var harness: String?
    /// A turn runs in it now.
    public var working: Bool
    /// Its last turn is over (idle, failed or lost); false while a turn runs, waits on the person,
    /// or nothing is known.
    public var turnEnded: Bool

    public init(key: String, session: String?, agentSession: String? = nil, workspaceID: String? = nil,
                harness: String? = nil, working: Bool = false, turnEnded: Bool = false) {
        self.key = key
        self.session = session
        self.agentSession = agentSession
        self.workspaceID = workspaceID
        self.harness = harness
        self.working = working
        self.turnEnded = turnEnded
    }

    /// Whether a lane in `state` has ended its turn.
    public static func turnEnded(_ state: AgentActivityLane.State?) -> Bool {
        switch state {
        case .idle, .failed, .lost: true
        case .working, .input, nil: false
        }
    }

    /// The chats of tabs `keys`: each tab's acpmux session (`session`) and that session's lane
    /// (its harness, workspace, harness session id and whether it works).
    public static func chats(keys: some Sequence<String>, session: (String) -> String?,
                             lanes: [String: AgentActivityLane]) -> [ComputerUsePreviewChat] {
        keys.sorted().map { key in
            let id = session(key)
            let lane = id.flatMap { lanes[$0] }
            let agentSession = lane?.chat.flatMap { $0.split(separator: ":", maxSplits: 1).last.map(String.init) }
            return ComputerUsePreviewChat(key: key, session: id, agentSession: agentSession, workspaceID: lane?.workspaceID,
                                          harness: lane?.harness, working: lane?.state == .working,
                                          turnEnded: turnEnded(lane?.state))
        }
    }
}

/// Which agent chat shows a Computer Use session's live preview card. The helper stamps the
/// session's agent from its MCP proxy's process (computer-use.md section 3); until the session
/// host attributes it (step d: `acp_session`, `harness_session_id`, `workspace_id`), nothing names
/// the chat, so the route falls back to the chat that is working, then the focused chat.
nonisolated enum ComputerUsePreviewRoute {
    /// The chat for `session`, and whether an id named it (`exact`) rather than a guess.
    struct Pick: Equatable, Sendable {
        var key: String
        var exact: Bool
    }

    /// In order: the chat of the session's `acp_session`; the chat of its harness session id; in
    /// its workspace, the one working chat (or the only chat); the one working chat of the same
    /// harness family; the focused chat. Nil when none fits.
    static func pick(for session: ComputerUsePreviewSession, chats: [ComputerUsePreviewChat], focused: String?) -> Pick? {
        if let acp = session.acpSession, let chat = chats.first(where: { $0.session == acp }) {
            return Pick(key: chat.key, exact: true)
        }
        if let harness = session.harnessSessionID, let chat = chats.first(where: { $0.agentSession == harness }) {
            return Pick(key: chat.key, exact: true)
        }
        let family = Self.family(session.agentKind)
        let fits = chats.filter { $0.session != nil && Self.compatible(family, Self.family($0.harness)) }
        if let workspace = session.workspaceID {
            let here = fits.filter { $0.workspaceID == workspace }
            let working = here.filter(\.working)
            if working.count == 1, let only = working.first { return Pick(key: only.key, exact: false) }
            if here.count == 1, let only = here.first { return Pick(key: only.key, exact: false) }
        }
        let working = fits.filter(\.working)
        if working.count == 1, let only = working.first { return Pick(key: only.key, exact: false) }
        // No chat works, or several do: nothing better than the focused chat is known.
        if let focused, chats.contains(where: { $0.key == focused }) { return Pick(key: focused, exact: false) }
        return nil
    }

    /// The agent family of a session's `agent.kind` or a chat's harness: `claude`, `codex`, the
    /// harness of `acp:<harness>`; nil when it says nothing (`unknown`, `cli`, a process name).
    static func family(_ kind: String?) -> String? {
        guard var kind = kind?.lowercased(), !kind.isEmpty else { return nil }
        if kind.hasPrefix("acp:") { kind.removeFirst(4) }
        if kind.hasPrefix("claude") { return "claude" }
        if kind.hasPrefix("codex") { return "codex" }
        if kind.hasPrefix("opencode") { return "opencode" }
        return nil
    }

    private static func compatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }
}
