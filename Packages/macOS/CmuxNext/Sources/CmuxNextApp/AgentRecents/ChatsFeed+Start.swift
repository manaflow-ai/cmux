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
        SidebarSessionTreeFeed.shared.start(services, localHost: localHost) // the sidebar's session tree reads these lanes
        return ChatsFeed(socketPath: environment.socketPath)
    }
}
