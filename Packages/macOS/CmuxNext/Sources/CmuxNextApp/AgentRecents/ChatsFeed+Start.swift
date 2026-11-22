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
        turns.start(localHost: (try? services.cloud.localDeviceID()).map(AgentSessionRef.host(installID:)))
        return ChatsFeed(socketPath: environment.socketPath)
    }
}
