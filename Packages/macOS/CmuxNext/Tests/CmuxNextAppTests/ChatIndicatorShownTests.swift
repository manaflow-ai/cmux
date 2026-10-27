@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLaunch
import Testing

/// What the windows show of the agent chat tabs' indicators at launch (p08-startup-097, `ChatsFeed.shown`): this
/// Mac's chat tabs need its watches right after the first frame, a Chief subagent tab the Chief home's; a terminal
/// or another machine's chat needs neither.
@MainActor @Suite struct ChatIndicatorShownTests {
    private static let local = "install:this-mac", chief = "chief:home"

    private static func workspaces(hosts: [String?]) -> [WorkspaceModel] {
        let tabs = hosts.enumerated().map { index, host -> TabSnapshot in
            let surface = SurfaceID(rawValue: UInt64(index + 1))
            guard let host else { return TabSnapshot(surface: surface, title: "zsh") }
            var tab = TabSnapshot(surface: surface, kind: .conversation, title: "Chat", url: "about:blank")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host))
            return tab
        }
        let store = DaemonStore()
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store.workspaces
    }

    @Test func thisMacsChatTabNeedsItsWatchesOnly() {
        let shown = ChatsFeed.shown(Self.workspaces(hosts: [nil, Self.local]), localHost: Self.local, chiefHost: Self.chief)
        #expect(shown == ChatIndicatorLaunch.Shown(indicators: true, chief: false))
    }

    @Test func aChiefSubagentTabNeedsTheChiefWatch() {
        let shown = ChatsFeed.shown(Self.workspaces(hosts: [Self.chief, Self.local]), localHost: Self.local, chiefHost: Self.chief)
        #expect(shown == ChatIndicatorLaunch.Shown(indicators: true, chief: true))
    }

    @Test func terminalsAndAnotherMachinesChatsNeedNoWatch() {
        let shown = ChatsFeed.shown(Self.workspaces(hosts: [nil, "install:other-mac"]), localHost: Self.local, chiefHost: Self.chief)
        #expect(shown == ChatIndicatorLaunch.Shown())
    }

    /// The placed Chief item draws the Chief's status and subagent rows with no Chief tab open.
    @Test func aPlacedChiefItemNeedsTheChiefWatch() {
        let sidebar = ChatsFeed.sidebarShown(sessionTree: false, priorityView: false, chiefPlaced: true)
        let shown = ChatsFeed.shown(Self.workspaces(hosts: [nil]), localHost: Self.local, chiefHost: Self.chief, sidebar: sidebar)
        #expect(shown == ChatIndicatorLaunch.Shown(indicators: false, chief: true))
    }

    /// The session tree draws this Mac's chats and their turn states (its chat history too) with no chat tab open.
    @Test func theSessionTreeNeedsThisMacsWatches() {
        let sidebar = ChatsFeed.sidebarShown(sessionTree: true, priorityView: false, chiefPlaced: false)
        let shown = ChatsFeed.shown(Self.workspaces(hosts: [nil]), localHost: Self.local, chiefHost: Self.chief, sidebar: sidebar)
        #expect(shown == ChatIndicatorLaunch.Shown(indicators: true, chief: false))
    }

    @Test func thePriorityViewNeedsThisMacsWatches() {
        #expect(ChatsFeed.sidebarShown(sessionTree: false, priorityView: true, chiefPlaced: false).indicators)
    }

    /// The default sidebar (no session tree, no Priority view, no Chief item) needs nothing of its own.
    @Test func theDefaultSidebarNeedsNoWatch() {
        let sidebar = ChatsFeed.sidebarShown(sessionTree: false, priorityView: false, chiefPlaced: false)
        #expect(sidebar == ChatIndicatorLaunch.Shown())
        #expect(ChatsFeed.shown(Self.workspaces(hosts: [nil]), localHost: Self.local, chiefHost: Self.chief, sidebar: sidebar) == sidebar)
    }

    /// Before this Mac's install id is known, any chat tab not the Chief's counts as this Mac's.
    @Test func anUnknownLocalHostCountsEveryNonChiefChat() {
        let shown = ChatsFeed.shown(Self.workspaces(hosts: ["install:other-mac"]), localHost: nil, chiefHost: Self.chief)
        #expect(shown.indicators)
        #expect(!shown.chief)
    }
}
