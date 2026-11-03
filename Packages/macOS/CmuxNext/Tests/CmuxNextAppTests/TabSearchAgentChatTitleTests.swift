import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing
@testable import CmuxNextApp

/// Search Tabs (`tab.search`, and `tabs.search` from the same entries) names
/// a tab the way the tab strip does. An agent chat's record carries the
/// `about:blank` address of the page that draws it, and the page listed the
/// chat as "about:blank".
@MainActor
struct TabSearchAgentChatTitleTests {
    private static let host = "install:this-mac"

    @Test func anAgentChatIsListedByTheStripsNameNotItsRecord() throws {
        let daemon = DaemonService()
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: "s-chat", harness: "claude"))
        let shell = TabSnapshot(surface: 2, kind: .pty, title: "zsh")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, shell])])
        daemon.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "Transparent popover readability", screens: [screen]),
        ]))
        let workspace = try #require(daemon.store.workspaces.first)
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: [:], showcase: true)
        tabs.localHost = Self.host
        var strip = TabTitleResolver(agentTabs: tabs)
        strip.workspaceName = workspace.displayName
        let chatTab = try #require(daemon.store.tab(surface: 1))
        let shown = strip.title(chatTab)
        #expect(!shown.lowercased().contains("about:blank"))

        let topology = ControlTopology(store: daemon.store, selectedTab: { _ in nil })
        let facts = ControlTabSearchFacts(titles: TabSearchFactsBuilder.titles([workspace], TabTitleResolver(agentTabs: tabs)))
        let entries = TabSearchEntries.entries(topology, facts)
        let listed = try #require(entries.first { $0.id == chatTab.id })
        #expect(listed.title == shown)
        // Other tabs keep their topology title.
        let shellTab = try #require(daemon.store.tab(surface: 2))
        #expect(entries.first { $0.id == shellTab.id }?.title == "zsh")
        #expect(!entries.contains { $0.title.lowercased().contains("about:blank") })
    }
}
