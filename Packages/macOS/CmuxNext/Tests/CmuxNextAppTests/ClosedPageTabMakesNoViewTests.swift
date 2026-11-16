import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A pane can ask for a closed page tab's view after its close was seen (its strip still held the
/// tab for a frame, 2026-11-15 Settings trace: 35-80 ms after Cmd-W). That made a new view
/// around the closed tab's page, kept by nothing that ever let it go: the Settings page and its
/// claimed pool host stayed alive, and with the pool's two hosts held, the next Cmd-, found no
/// parked spare and built its page cold.
@MainActor
struct ClosedPageTabMakesNoViewTests {
    private final class Page: InternalPageProvider {
        let page = InternalPageID.settings
        var title = "Settings"
        var symbol = "gear"
        var made = 0
        var closed: [String] = []

        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return NSView()
        }

        func tabClosed(_ key: String) { closed.append(key) }
    }

    private static func tree(_ tabs: [TabSnapshot]) -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: tabs)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    @Test func aClosedPageTabGetsNoNewView() throws {
        let store = DaemonStore()
        try WorkspaceChecklistTests.handshake(store, capabilities: [])
        var settings = TabSnapshot(surface: 1, kind: .conversation, title: "Settings")
        settings.conversation = ConversationTabRef(page: InternalPageID.settings.rawValue, route: nil)
        store.apply(snapshot: Self.tree([settings, TabSnapshot(surface: 2, kind: .pty, title: "zsh")]))
        let tab = try #require(store.tab(surface: 1))
        #expect(store.liveTreeLists(tab: tab.id) == true)

        let pages = InternalPageTabStore()
        let provider = Page()
        pages.register(provider)
        #expect(pages.view(forStoreTab: tab, in: store, local: true, window: nil) != nil)
        #expect(provider.made == 1)

        // Cmd-W: the tree drops the tab and the store lets its view go.
        store.apply(snapshot: Self.tree([TabSnapshot(surface: 2, kind: .pty, title: "zsh")]))
        #expect(store.liveTreeLists(tab: tab.id) == false)
        pages.closeGoneStoreTabs(in: store)
        #expect(provider.closed.count == 1)

        // A pane whose strip still holds the closed tab asks for it once more.
        #expect(pages.view(forStoreTab: tab, in: store, local: true, window: nil) == nil,
                "a closed tab's view was made again, holding its page with nothing to let it go")
        #expect(provider.made == 1)
    }
}
