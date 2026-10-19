nonisolated extension DeepLink {
    /// A terminal tab that may run an outside agent: the agent and the
    /// harness session id its hooks reported (`TabModel.agent`).
    public nonisolated struct AgentCandidate: Sendable, Hashable {
        /// The tab's id (`TabModel.id`).
        public var tab: String
        /// The agent the hooks named (`claude`, `codex`); nil when unknown.
        public var harness: String?
        /// The harness's own session id; nil when none was reported.
        public var session: String?

        public init(tab: String, harness: String?, session: String?) {
            self.tab = tab
            self.harness = harness
            self.session = session
        }
    }

    /// The tab an `agent/<harness>/<session>` link opens, among the tabs this
    /// app can already reach: the agent chat tab that adopted that session
    /// first, else the first terminal whose agent reported that session (a
    /// terminal whose agent names another harness is skipped; one that names
    /// none matches by the session alone). Nil when no tab shows it: the link
    /// never starts, resumes or attaches to anything.
    ///
    /// - Parameters:
    ///   - harness: The link's harness (lowercase).
    ///   - session: The link's harness session id.
    ///   - adopted: The agent chat tab resuming `harness:session`, if any.
    ///   - terminals: The terminal tabs of the connected machines, in order.
    /// - Returns: The tab id to reveal, or nil.
    public static func agentTab(harness: String, session: String, adopted: String?, terminals: [AgentCandidate]) -> String? {
        if let adopted { return adopted }
        return terminals.first { candidate in
            candidate.session == session && (candidate.harness.map { $0.lowercased() == harness } ?? true)
        }?.tab
    }

    /// Where the keyboard goes after an agent link revealed its tab.
    public nonisolated enum AgentFocus: Sendable, Hashable {
        /// Focus stays where it was (a background open).
        case none
        /// The agent chat tab's composer takes the keyboard.
        case focusComposer
        /// The terminal running the agent takes the keyboard.
        case focusTerminal
    }

    /// The focus an agent link's open asks for: the revealed session's input,
    /// so talking to the agent takes one keystroke, only when the user opened
    /// the link; a background open (Cmd held, or a run the user did not
    /// start) never moves focus. The link itself never types or sends.
    ///
    /// - Parameters:
    ///   - chatTab: The revealed tab is an agent chat tab (else a terminal).
    ///   - background: The open must not take focus.
    public static func agentFocus(chatTab: Bool, background: Bool) -> AgentFocus {
        guard !background else { return .none }
        return chatTab ? .focusComposer : .focusTerminal
    }
}
