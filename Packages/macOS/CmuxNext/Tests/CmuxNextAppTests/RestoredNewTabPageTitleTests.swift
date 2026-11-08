import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// A New Tab page left open at quit comes back after a relaunch as a store tab with a blank chat
/// record (cx-eqkt0). Before anything shows it, the strip and the sidebar already name it
/// "New Tab" with the page's badge, as they did before the quit; a chat tab stays a chat.
@MainActor
struct RestoredNewTabPageTitleTests {
    private static let host = "install:this-mac"

    /// One pane as the store restores it: a blank New Tab page and a chat with a session.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host))
        var chat = TabSnapshot(surface: 2, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-chat", harness: "claude"))
        let pane = PaneSnapshot(id: 1, tabs: [page, chat])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    /// The app's agent tabs after a relaunch: they know this Mac and the store, and have made no view.
    private static func agentTabs(_ store: DaemonStore) -> AgentTabStore {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: [:], showcase: true)
        tabs.localHost = host
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        return tabs
    }

    @Test func aRestoredNewTabPageIsNamedNewTabBeforeItShows() throws {
        let store = Self.store()
        let tabs = Self.agentTabs(store)
        let page = try #require(store.tab(surface: 1))
        let chat = try #require(store.tab(surface: 2))
        let titles = TabTitleResolver(agentTabs: tabs)
        #expect(titles.title(page) == Strings.untitledBrowser)
        #expect(titles.title(chat) == AgentChatTabTitle.untitled(chat.agentSession))
        // The sidebar lists it as a page too (its row's title and badge).
        let pages = SidebarBridge.newTabPages(tabs, in: store)
        #expect(pages.contains(page.id))
        #expect(!pages.contains(chat.id))
    }

    /// A restored blank tab with a draft typed before the quit opens as that chat, not the page.
    @Test func aRestoredBlankTabWithAnUnsentDraftStaysAChat() throws {
        let store = Self.store()
        let tabs = Self.agentTabs(store)
        let page = try #require(store.tab(surface: 1))
        let file = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode([page.id: "fix the flaky upload test"]).write(to: file)
        tabs.unsentDrafts = AgentUnsentDrafts(file: file, files: AgentPaneStateFiles())
        #expect(TabTitleResolver(agentTabs: tabs).title(page) == AgentChatTabTitle.untitled(page.agentSession))
        #expect(!SidebarBridge.newTabPages(tabs, in: store).contains(page.id))
    }
}
