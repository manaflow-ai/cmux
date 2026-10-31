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

    /// The tabs an `agent/<harness>/<session>` link may open, best first,
    /// among the tabs this app can already reach: the agent chat tab that
    /// adopted that session, then the terminals whose agent reported that
    /// session under the link's harness, then those whose agent names no
    /// harness we know (a Claude Code subagent reports its agent type, such
    /// as `general-purpose`). A terminal whose agent names another harness is
    /// skipped. Empty when no tab shows it: the link never starts, resumes or
    /// attaches to anything.
    ///
    /// - Parameters:
    ///   - harness: The link's harness (lowercase).
    ///   - session: The link's harness session id.
    ///   - adopted: The agent chat tab resuming `harness:session`, if any.
    ///   - terminals: The terminal tabs of the connected machines, in order.
    /// - Returns: The tab ids to try revealing, in order: a tab that fails to
    ///   reveal falls through to the next one showing the session.
    public static func agentTabs(harness: String, session: String, adopted: String?, terminals: [AgentCandidate]) -> [String] {
        let running = terminals.filter { $0.session == session }
        let named = running.filter { knownHarness($0.harness) == harness }
        let unnamed = running.filter { knownHarness($0.harness) == nil }
        return (adopted.map { [$0] } ?? []) + (named + unnamed).map(\.tab)
    }

    /// ``agentTabs(harness:session:adopted:terminals:)`` over the daemon's harness sessions.
    public static func agentTabs(harness: String, session: String, adopted: String?,
                                 harnessSessions: [(tab: String, agent: String?, session: String)]) -> [String] {
        agentTabs(harness: harness, session: session, adopted: adopted,
                  terminals: harnessSessions.map { AgentCandidate(tab: $0.tab, harness: $0.agent, session: $0.session) })
    }

    /// The first of ``agentTabs(harness:session:adopted:terminals:)``.
    public static func agentTab(harness: String, session: String, adopted: String?, terminals: [AgentCandidate]) -> String? {
        agentTabs(harness: harness, session: session, adopted: adopted, terminals: terminals).first
    }

    /// The first of ``agentTabs(harness:session:adopted:harnessSessions:)``.
    public static func agentTab(harness: String, session: String, adopted: String?,
                                harnessSessions: [(tab: String, agent: String?, session: String)]) -> String? {
        agentTabs(harness: harness, session: session, adopted: adopted, harnessSessions: harnessSessions).first
    }

    /// The harnesses a terminal's reported agent can name. Hooks report
    /// `agent_type` first, which is not always a harness.
    static let knownHarnesses: Set<String> = ["claude", "codex", "opencode", "gemini", "muse"]

    /// The harness a reported agent names, or nil when it names none we
    /// know. Claude Code's hooks may say `claude-code`.
    static func knownHarness(_ agent: String?) -> String? {
        guard let agent = agent?.lowercased() else { return nil }
        if agent == "claude-code" { return "claude" }
        return knownHarnesses.contains(agent) ? agent : nil
    }
}
