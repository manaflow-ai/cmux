import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing
@testable import CmuxNextApp

/// Search All Windows names a tab the way the tab strip does. An agent chat's
/// record carries the `about:blank` address of the page that draws it; a
/// search for its workspace's name showed a row titled "about:blank" with
/// the place "Transparent popover readability › about:blank".
@MainActor
struct GlobalSearchTabTitleTests {
    private static let host = "install:this-mac"

    @Test func anAgentChatMatchedByItsWorkspaceIsNamedLikeTheStrip() async throws {
        let daemon = DaemonService()
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: "s-chat", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        daemon.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "Transparent popover readability", screens: [screen]),
        ]))
        let workspace = try #require(daemon.store.workspaces.first)
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: [:], showcase: true)
        tabs.localHost = Self.host
        let titles = TabTitleResolver(agentTabs: tabs)
        let shown = try #require(daemon.store.tab(surface: 1).map(titles.title))
        #expect(!shown.lowercased().contains("about:blank"))

        let searched = GlobalSearchHandlers.searchable([(workspace, daemon)], titles: titles)
        let corpus = await GlobalSearchCorpus.load(searched.map(\.source))
        let words = GlobalSearchCorpus.words("transparent")
        let found = await corpus.hits(words)
        let rows = GlobalSearchPage.items(found.hits, limited: found.limited, unreadable: corpus.unreadable, words: words,
                                          byTab: Dictionary(uniqueKeysWithValues: searched.map { ($0.source.tabID, $0) }),
                                          reveal: { _, _ in }, done: {})
        let row = try #require(rows.first)
        #expect(row.title == shown)
        #expect(row.subtitle == "Transparent popover readability › \(shown)")
        #expect(await corpus.hits(GlobalSearchCorpus.words("about:blank")).hits.isEmpty, "the page's address is not the tab's name")
    }
}
