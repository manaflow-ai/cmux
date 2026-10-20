extension WorkspaceModel {
    /// Every live tab whose agent hooks reported a harness session id, in order: the tab id, the
    /// agent (`claude`, `codex`) when known, and the session. Hook bookkeeping values
    /// (`cmux-hook-…`) are not a session, and an exited terminal keeps its last report but no
    /// longer runs it. `cmux://agent` links (hq#2555) resolve against these.
    public var agentHarnessSessions: [(tab: String, agent: String?, session: String)] {
        screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            guard !tab.dead, let session = tab.agent?.session, !session.isEmpty, !session.hasPrefix("cmux-hook-") else { return nil }
            return (tab.id, tab.agent?.agent, session)
        }
    }
}

extension DaemonStore {
    /// ``WorkspaceModel/agentHarnessSessions`` of every workspace while this daemon is connected;
    /// none while it is not, because a disconnected machine keeps its last tree but none of its
    /// terminals can be reached.
    public var reachableAgentHarnessSessions: [(tab: String, agent: String?, session: String)] {
        guard case .connected = connectionState else { return [] }
        return workspaces.flatMap(\.agentHarnessSessions)
    }
}
