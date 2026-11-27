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
/// the chat, so the route guesses the one working chat of the session's agent family. A guess that
/// is not sure shows no card: a card in a chat that does not own the session is worse than none.
nonisolated enum ComputerUsePreviewRoute {
    /// The chat for `session`, and whether an id named it (`exact`) rather than a guess.
    struct Pick: Equatable, Sendable {
        var key: String
        var exact: Bool
    }

    /// Prefer a unique acpmux session ID, then a unique harness session ID. Both must agree with
    /// the helper's workspace when known. Harness IDs are local to their harness, so their family
    /// must also agree. A conflicting or ambiguous ID never puts another agent's window in a chat.
    /// Only sessions without either ID can use the single-working-chat fallback.
    static func pick(for session: ComputerUsePreviewSession, chats: [ComputerUsePreviewChat]) -> Pick? {
        func sameWorkspace(_ chat: ComputerUsePreviewChat) -> Bool {
            guard let workspace = session.workspaceID else { return true }
            return chat.workspaceID == workspace
        }
        func unique(_ candidates: [ComputerUsePreviewChat]) -> Pick? {
            guard candidates.count == 1, let chat = candidates.first else { return nil }
            return Pick(key: chat.key, exact: true)
        }
        if let acp = session.acpSession {
            let candidates = chats.filter { $0.session == acp && sameWorkspace($0) }
            // A duplicated acpmux id is ambiguous even when a harness id would select one.
            if candidates.count > 1 { return nil }
            if let found = unique(candidates) { return found }
        }
        if let harness = session.harnessSessionID {
            let candidates = chats.filter { chat in
                guard chat.agentSession == harness, sameWorkspace(chat) else { return false }
                guard let expected = Self.family(session.agentKind) else { return true }
                return Self.family(chat.harness) == expected
            }
            return unique(candidates)
        }
        // Its own chat is not open here: no other chat owns it.
        guard session.acpSession == nil else { return nil }
        let open = chats.filter { $0.session != nil }
        let here = session.workspaceID.map { workspace in open.filter { $0.workspaceID == workspace } } ?? open
        guard let family = Self.family(session.agentKind) else {
            let working = open.filter(\.working)
            guard working.count == 1, let only = working.first, here.contains(only) else { return nil }
            return Pick(key: only.key, exact: false)
        }
        let fits = here.filter { Self.family($0.harness).map { $0 == family } ?? true }
        let working = fits.filter(\.working)
        if working.count == 1, let only = working.first { return Pick(key: only.key, exact: false) }
        if session.workspaceID != nil, fits.count == 1, let only = fits.first {
            return Pick(key: only.key, exact: false)
        }
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
}
