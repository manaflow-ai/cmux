import CmuxNextAgentLanes
import CmuxNextDaemon

extension ChatsFeed {
    /// The app's Chats feed, and with it the acpmux turn-state watch for the
    /// working and needs-input indicators of agent chat tabs
    /// (WORKING-AND-LOADING-INDICATORS), whether or not a window shows Chats.
    /// Nil without a local acpmux environment.
    static func started(for services: AppServices) -> ChatsFeed? {
        guard let environment = QuitAgents.environment(services) else { return nil }
        let turns = AgentTurnStateFeed.shared ?? AgentTurnStateFeed(socketPath: environment.socketPath)
        AgentTurnStateFeed.shared = turns
        AgentTurnStateFeed.drained = { DebugTimings.turnStatesApplied(lines: $0, $1) }
        let localHost = (try? services.cloud.localDeviceID()).map(AgentSessionRef.host(installID:))
        turns.start(localHost: localHost)
        SidebarSessionTreeFeed.shared.start(workspaces: { services.machines.allWorkspaces.map { $0.0 } }, localHost: localHost)
        let feed = ChatsFeed(socketPath: environment.socketPath)
        // The session tree's chat history: rows open through the shared Open Chat path.
        let history = SidebarChatHistoryFeed.shared
        feed.observe(history) { [weak feed] in if let feed { history.chats = feed.store } }
        history.start(workspaces: { services.machines.allWorkspaces.map { $0.0 } }, localHost: localHost,
                      open: { [weak services] key in services?.chatsOpener.open(key) })
        return feed
    }
}
