extension WorkspaceModel {
    /// Every live tab whose agent runs a harness session (``AgentStatus/harnessSessionID``), in
    /// order: the tab id, the agent (`claude`, `codex`) when known, and the session. An exited
    /// terminal keeps its last report but no longer runs it, and an ended session (`done`, a
    /// hook's SessionEnd) keeps its id but no longer runs. `cmux://agent` links (hq#2555)
    /// resolve against these.
    public var agentHarnessSessions: [(tab: String, agent: String?, session: String)] {
        screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            guard !tab.dead, let agent = tab.agent, agent.state != .done, let session = agent.harnessSessionID else {
                return nil
            }
            return (tab.id, agent.agent, session)
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
