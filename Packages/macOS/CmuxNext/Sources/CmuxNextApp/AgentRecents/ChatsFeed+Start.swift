import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextHomeEngine
import CmuxNextDaemon
import CmuxNextWakeups

extension ChatsFeed {
    /// The app's Chats feed, and with it the acpmux turn-state watch for the
    /// working and needs-input indicators of agent chat tabs
    /// (WORKING-AND-LOADING-INDICATORS), whether or not a window shows Chats.
    /// Nil without a local acpmux environment.
    static func started(for services: AppServices) -> ChatsFeed? {
        guard let environment = QuitAgents.environment(services) else { return nil }
        let turns = AgentTurnStateFeed.shared ?? AgentTurnStateFeed(socketPath: environment.socketPath, deadlines: services.mainDeadlines)
        AgentTurnStateFeed.shared = turns
        AgentTurnStateFeed.drained = { DebugTimings.turnStatesApplied(lines: $0, $1) }
        // A deleted chat's uploads go with it; any past their age at launch (``AgentChatUploads``).
        AgentTurnStateFeed.purged = { AgentChatUploads.removeInBackground(session: $0) }
        AgentChatUploads.sweepInBackground()
        let localHost = (try? services.cloud.localDeviceID()).map(AgentSessionRef.host(installID:))
        turns.start(localHost: localHost)
        startChiefTurnStates(tag: services.environment.tag, deadlines: services.mainDeadlines)
        SidebarSessionTreeFeed.shared.start(workspaces: { services.machines.allWorkspaces.map { $0.0 } }, localHost: localHost,
                                            reader: services.pullRequests.reader, deadlines: services.mainDeadlines)
        let feed = ChatsFeed(socketPath: environment.socketPath, deadlines: services.mainDeadlines,
                             drained: { DebugTimings.chatsFeedApplied(lines: $0, $1) })
        // The session tree's chat history: two windows acpmux keeps (never the whole index); rows
        // open through the shared Open Chat path.
        SidebarChatHistoryFeed.shared.start(workspaces: { services.machines.allWorkspaces.map { $0.0 } }, localHost: localHost,
                                            open: { [weak services] key in services?.chatsOpener.open(key) }, windows: feed.windows,
                                            mainWork: services.mainWork)
        return feed
    }

    /// The Chief home's acpmux watch (2026-10-20: every Chief subagent tab read "Agent"): the
    /// Chief runs its subagents there, and their tabs name its `chief:<id>` host, so their
    /// titles and turn states come from that watch. It keeps its own activity lanes (`AgentLaneStore.chief`).
    static func startChiefTurnStates(tag: String?, deadlines: MainDeadlineScheduler) {
        guard chiefTurnStates == nil else { return }
        let home = ChiefHome.resolve(tag: tag)
        guard let environment = ChiefHomeAcpmux.environment(home: home) else { return }
        let feed = AgentTurnStateFeed(socketPath: environment.socketPath, lanes: .chief,
                                      mirroring: ChiefHomeAcpmux.host(muxHome: home.muxHome), deadlines: deadlines)
        chiefTurnStates = feed
        feed.start(localHost: nil)
    }

    /// The Chief home's watch, once started.
    static var chiefTurnStates: AgentTurnStateFeed?
}
