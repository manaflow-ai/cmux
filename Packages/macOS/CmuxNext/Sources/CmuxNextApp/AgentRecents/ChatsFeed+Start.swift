import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextHomeEngine
import CmuxNextDaemon

extension ChatsFeed {
    /// The app's Chats feed, and with it the acpmux turn-state watch for the
    /// working and needs-input indicators of agent chat tabs
    /// (WORKING-AND-LOADING-INDICATORS), whether or not a window shows Chats.
    /// Nil without a local acpmux environment.
    static func started(for services: AppServices) -> ChatsFeed? {
        guard let environment = QuitAgents.environment(services) else {
            // The showcase has no acpmux daemon, but the DEBUG pull-request fixture
            // still needs the real sidebar feed to publish its sample badges. With a
            // real environment, normal startup below preserves the local host identity.
            if SidebarPullRequestFixture.enabled {
                SidebarSessionTreeFeed.shared.start(workspaces: { services.machines.allWorkspaces.map { $0.0 } }, localHost: nil)
            }
            return nil
        }
        // An acpmux peer that connects later in the launch gets the app's build too.
        let turns = AgentTurnStateFeed.shared ?? AgentTurnStateFeed(socketPath: environment.socketPath,
                                                                   peerSessionChanged: { [updates = services.daemonUpdates] in updates.peerSessionChanged($0, stale: $1) })
        AgentTurnStateFeed.shared = turns
        AgentTurnStateFeed.drained = { DebugTimings.turnStatesApplied(lines: $0, $1) }
        // A deleted chat's uploads go with it; any past their age at launch (``AgentChatUploads``).
        AgentTurnStateFeed.purged = { AgentChatUploads.removeInBackground(session: $0) }
        AgentChatUploads.sweepInBackground()
        let localHost = (try? services.cloud.localDeviceID()).map(AgentSessionRef.host(installID:))
        turns.start(localHost: localHost)
        startChiefTurnStates(tag: services.environment.tag)
        SidebarSessionTreeFeed.shared.start(workspaces: { services.machines.allWorkspaces.map { $0.0 } }, localHost: localHost)
        let feed = ChatsFeed(socketPath: environment.socketPath, drained: { DebugTimings.chatsFeedApplied(lines: $0, $1) })
        // The session tree's chat history: two windows acpmux keeps (never the whole index); rows
        // open through the shared Open Chat path.
        SidebarChatHistoryFeed.shared.start(workspaces: { services.machines.allWorkspaces.map { $0.0 } }, localHost: localHost,
                                            open: { [weak services] key in services?.chatsOpener.open(key) }, windows: feed.windows)
        return feed
    }

    /// The Chief home's acpmux watch (2026-10-20: every Chief subagent tab read "Agent"): the
    /// Chief runs its subagents there, and their tabs name its `chief:<id>` host, so their
    /// titles and turn states come from that watch. It keeps its own activity lanes (`AgentLaneStore.chief`).
    static func startChiefTurnStates(tag: String?) {
        guard chiefTurnStates == nil else { return }
        let home = ChiefHome.resolve(tag: tag)
        guard let environment = ChiefHomeAcpmux.environment(home: home) else { return }
        let feed = AgentTurnStateFeed(socketPath: environment.socketPath, lanes: .chief,
                                      mirroring: ChiefHomeAcpmux.host(muxHome: home.muxHome))
        chiefTurnStates = feed
        feed.start(localHost: nil)
    }

    /// The Chief home's watch, once started.
    static var chiefTurnStates: AgentTurnStateFeed?
}
