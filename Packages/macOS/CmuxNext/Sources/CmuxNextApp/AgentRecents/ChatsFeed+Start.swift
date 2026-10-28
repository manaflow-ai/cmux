import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextHomeEngine
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import Foundation

extension ChatsFeed {
    /// The app's Chats feed, not connected yet (its first observer connects it). Nil without a local acpmux environment.
    static func made(for services: AppServices) -> ChatsFeed? {
        guard let environment = QuitAgents.environment(services) else { return nil }
        return ChatsFeed(socketPath: environment.socketPath, deadlines: services.mainDeadlines)
    }

    /// Posts the acpmux watches behind the agent chat tabs' working and needs-input indicators
    /// (WORKING-AND-LOADING-INDICATORS) and the chat uploads' sweep, none before the first frame (p08-startup-097,
    /// ``ChatIndicatorLaunch``): right after it when a window or an agent page shows them, else after startup. It makes
    /// no feed and resolves nothing now: each start takes the Chats feed when it runs. Once per launch.
    static func postLaunchIndicators(for services: AppServices, startup: StartupScheduler) {
        guard services.chatIndicators == nil else { return }
        let launch = ChatIndicatorLaunch(startup: startup, starts: indicatorStarts(for: services))
        services.chatIndicators = launch
        launch.post()
        // The first look can come before the restore made the saved windows and their tabs: look again after it.
        services.windows.whenRestored { [weak launch] in launch?.checkShown() }
    }

    /// An agent page or a Home view shows: Home and the New Tab page's feeds (p08-startup-027) and the indicator
    /// watches (p08-startup-097) start right after the first frame instead of after startup.
    static func pageShown(in services: AppServices) {
        services.home.launchFeeds?.need()
        services.chatIndicators?.pageShown()
    }

    /// Runs `body` with the Chats feed once main's acpmux resolve landed and this Mac's host can be known (the launch's
    /// read of its install id ended, p08-startup-076): a watch keeps the host it starts with, so none starts while
    /// that read runs. Nothing without a local acpmux.
    private static func whenReady(_ services: AppServices, _ owner: String,
                                  _ body: @escaping @MainActor @Sendable (AppServices, ChatsFeed) -> Void) {
        QuitAgents.whenResolved(services, owner: owner) { [weak services] _ in
            guard let services, services.chatsFeed != nil else { return }
            services.agentTabs.whenLocalHostKnown { [weak services] in
                if let services, let feed = services.chatsFeed { body(services, feed) }
            }
        }
    }

    /// The app's watch starts. This Mac's host is `AgentTabStore.localHost` (the Cloud device ID, the launch's read).
    private static func indicatorStarts(for services: AppServices) -> ChatIndicatorLaunch.Starts {
        let tag = services.environment.tag
        return ChatIndicatorLaunch.Starts(
            turnStates: { [weak services] in
                guard let services else { return }
                whenReady(services, "AgentTurnStates.start") { services, feed in
                    startTurnStates(socketPath: feed.socket, localHost: services.agentTabs.localHost,
                                    deadlines: services.mainDeadlines, connector: feed.connector)
                }
            },
            sessionTree: { [weak services] in
                guard let services else { return }
                whenReady(services, "SidebarSessionTree.start") { services, _ in
                    SidebarSessionTreeFeed.shared.start(workspaces: { [weak services] in services?.machines.allWorkspaces.map { $0.0 } ?? [] },
                                                        localHost: services.agentTabs.localHost, reader: services.pullRequests.reader,
                                                        deadlines: services.mainDeadlines)
                }
            },
            chatHistory: { [weak services] in
                guard let services else { return }
                whenReady(services, "SidebarChatHistory.start") { services, feed in
                    // The session tree's chat history: rows open through the shared Open Chat path.
                    let history = SidebarChatHistoryFeed.shared
                    feed.observe(history) { [weak feed] in if let feed { history.chats = feed.store } }
                    history.start(workspaces: { [weak services] in services?.machines.allWorkspaces.map { $0.0 } ?? [] },
                                  localHost: services.agentTabs.localHost, open: { [weak services] key in services?.chatsOpener.open(key) },
                                  mainWork: services.mainWork)
                }
            },
            chiefTurnStates: { [weak services] in
                guard let services else { return }
                QuitAgents.whenResolved(services, owner: "ChiefTurnStates.start") { [weak services] _ in
                    guard let services, let feed = services.chatsFeed else { return }
                    startChiefTurnStates(tag: tag, deadlines: services.mainDeadlines, connector: feed.connector)
                }
            },
            uploadSweep: {
                // A deleted chat's uploads go with it; any past their age at launch (``AgentChatUploads``).
                if let root = AgentChatUploads.root { _ = AgentChatUploads.sweep(root, now: Date()) }
            },
            shown: { [weak services] in
                guard let services else { return ChatIndicatorLaunch.Shown() }
                let sections = DesignSettings.shared.sidebarSections
                let sidebar = sidebarShown(sessionTree: sections.sessionTree, priorityView: sections.priorityViewEnabled,
                                           chiefPlaced: ChiefSidebar.shared.isPlaced)
                // Only a host already read: this look neither waits for the id nor logs its absence.
                return shown(services.machines.allWorkspaces.lazy.map { $0.0 }, localHost: services.agentTabs.resolvedLocalHost,
                             chiefHost: services.agentTabs.chiefHost, sidebar: sidebar)
            }
        )
    }

    /// What the sidebar shows of the watches with no chat tab open: the session tree (`sidebar.sessionTree`) and the
    /// Priority view draw this Mac's chats and their turn states; the placed Chief item draws the Chief's status and
    /// subagent rows.
    static func sidebarShown(sessionTree: Bool, priorityView: Bool, chiefPlaced: Bool) -> ChatIndicatorLaunch.Shown {
        ChatIndicatorLaunch.Shown(indicators: sessionTree || priorityView, chief: chiefPlaced)
    }

    /// What `sidebar` and `workspaces` show of the indicators: a chat tab of this Mac's acpmux (any chat tab not the
    /// Chief's while this Mac's host is not known yet) and a Chief subagent tab. It stops once both show.
    static func shown(_ workspaces: some Sequence<WorkspaceModel>, localHost: String?, chiefHost: String?,
                      sidebar: ChatIndicatorLaunch.Shown = .init()) -> ChatIndicatorLaunch.Shown {
        var shown = sidebar
        if shown.indicators, shown.chief { return shown }
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        guard let host = tab.agentSession?.host else { continue }
                        if let chiefHost, host == chiefHost {
                            shown.chief = true
                        } else if localHost == nil || host == localHost {
                            shown.indicators = true
                        }
                        if shown.indicators, shown.chief { return shown }
                    }
                }
            }
        }
        return shown
    }

    /// This Mac's acpmux turn-state watch, `AgentTurnStateFeed.shared`.
    private static func startTurnStates(socketPath: String, localHost: String?, deadlines: MainDeadlineScheduler,
                                        connector: AgentActivityConnector) {
        let turns = AgentTurnStateFeed.shared ?? AgentTurnStateFeed(socketPath: socketPath, deadlines: deadlines, connector: connector)
        AgentTurnStateFeed.shared = turns
        AgentTurnStateFeed.drained = { DebugTimings.turnStatesApplied(lines: $0, $1) }
        // A deleted chat's uploads go with it (``AgentChatUploads``).
        AgentTurnStateFeed.purged = { AgentChatUploads.removeInBackground(session: $0) }
        turns.start(localHost: localHost)
    }

    /// The Chief home's acpmux watch (2026-10-20: every Chief subagent tab read "Agent"): the
    /// Chief runs its subagents there, and their tabs name its `chief:<id>` host, so their
    /// titles and turn states come from that watch. It keeps its own activity lanes (`AgentLaneStore.chief`).
    static func startChiefTurnStates(tag: String?, deadlines: MainDeadlineScheduler, connector: AgentActivityConnector = .unixSocket) {
        guard chiefTurnStates == nil else { return }
        let home = ChiefHome.resolve(tag: tag)
        guard let environment = ChiefHomeAcpmux.environment(home: home) else { return }
        let feed = AgentTurnStateFeed(socketPath: environment.socketPath, lanes: .chief,
                                      mirroring: ChiefHomeAcpmux.host(muxHome: home.muxHome), deadlines: deadlines,
                                      connector: connector)
        chiefTurnStates = feed
        feed.start(localHost: nil)
    }

    /// The Chief home's watch, once started.
    static var chiefTurnStates: AgentTurnStateFeed?
}
