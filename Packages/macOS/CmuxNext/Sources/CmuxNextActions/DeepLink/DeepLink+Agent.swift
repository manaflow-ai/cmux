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
    ///   - harnessSessions: The terminal tabs of the connected machines, in order.
    /// - Returns: The tab id to reveal, or nil.
    public static func agentTab(harness: String, session: String, adopted: String?,
                                harnessSessions: [(tab: String, agent: String?, session: String)]) -> String? {
        agentTab(harness: harness, session: session, adopted: adopted,
                 terminals: harnessSessions.map { AgentCandidate(tab: $0.tab, harness: $0.agent, session: $0.session) })
    }

    /// ``agentTab(harness:session:adopted:harnessSessions:)`` over candidate values.
    public static func agentTab(harness: String, session: String, adopted: String?, terminals: [AgentCandidate]) -> String? {
        if let adopted { return adopted }
        return terminals.first { candidate in
            candidate.session == session && (candidate.harness.map { $0.lowercased() == harness } ?? true)
        }?.tab
    }
}
