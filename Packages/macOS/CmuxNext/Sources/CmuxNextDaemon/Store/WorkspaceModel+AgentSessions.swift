extension WorkspaceModel {
    /// Every tab whose agent hooks reported a harness session id, in order: the tab id, the
    /// agent (`claude`, `codex`) when known, and the session. Hook bookkeeping values
    /// (`cmux-hook-…`) are not a session. `cmux://agent` links (hq#2555) resolve against these.
    public var agentHarnessSessions: [(tab: String, agent: String?, session: String)] {
        screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            guard let session = tab.agent?.session, !session.isEmpty, !session.hasPrefix("cmux-hook-") else { return nil }
            return (tab.id, tab.agent?.agent, session)
        }
    }
}
