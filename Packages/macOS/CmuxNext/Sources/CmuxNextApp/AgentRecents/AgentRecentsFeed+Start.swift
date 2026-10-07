import CmuxNextDaemon

extension AgentRecentsFeed {
    /// The app's one acpmux watch, started with the services: it feeds the
    /// working and needs-input indicators of agent chat tabs
    /// (WORKING-AND-LOADING-INDICATORS) whether or not a window shows Recents.
    /// Nil without a local acpmux environment.
    static func started(for services: AppServices) -> AgentRecentsFeed? {
        guard let environment = QuitAgents.environment(services) else { return nil }
        let feed = AgentRecentsFeed(socketPath: environment.socketPath)
        feed.startTurnStates(localHost: (try? services.cloud.localDeviceID()).map(AgentSessionRef.host(installID:)))
        return feed
    }
}
