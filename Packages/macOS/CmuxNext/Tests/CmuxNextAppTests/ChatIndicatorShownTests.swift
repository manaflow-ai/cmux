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

    /// Before this Mac's install id is known, any chat tab not the Chief's counts as this Mac's.
    @Test func anUnknownLocalHostCountsEveryNonChiefChat() {
        let shown = ChatsFeed.shown(Self.workspaces(hosts: ["install:other-mac"]), localHost: nil, chiefHost: Self.chief)
        #expect(shown.indicators)
        #expect(!shown.chief)
    }
}
