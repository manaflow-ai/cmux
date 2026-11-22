import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat header's Changes (cx-u1yn): its diff opens beside the chat and on screen, and closing it
/// names the diff, not the page tab's `about:blank` address.
@MainActor
struct HeaderDiffPlacementTests {
    /// A scrolling screen of a chat column and a terminal column right of it, as the daemon lists
    /// it; a diff page tab in the terminal's column for the close.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let chat = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: .other("agentChat"))])
        var diff = TabSnapshot(surface: 3, kind: .conversation, title: "about:blank", url: "about:blank")
        diff.conversation = ConversationTabRef(page: "diff")
        let terminal = PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 2, kind: .pty), diff])
        let columns = [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1)), ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2))]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: [chat, terminal])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    /// The daemon's default for a new column is after the last one, past the terminal and out of
    /// view while the chat keeps focus. The diff's column goes right after the chat's instead.
    @Test func theDiffColumnOpensRightAfterTheChat() throws {
        let store = Self.store()
        let chat = try #require(store.pane(containing: 1))
        #expect(store.scrollingColumn(holding: chat) == ColumnID(rawValue: 10))
    }

    /// A chat docked to the edge is no scrolling column to follow: the daemon's default stands. (The
    /// daemon stores the chat's dock after the strip's last column, so naming it would not help.)
    @Test func aDockedChatKeepsTheDaemonsDefault() throws {
        let store = DaemonStore()
        let chat = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: .other("agentChat"))])
        let columns = [ColumnSnapshot(id: 10, width: 0.3, layout: .leaf(1), dock: DockSnapshot(edge: .left, mode: .docked))]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: [chat])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let pane = try #require(store.pane(containing: 1))
        #expect(store.scrollingColumn(holding: pane) == nil)
    }

    private final class DiffPage: InternalPageProvider {
        var page: InternalPageID { InternalPageID(rawValue: "diff") }
        var title: String { "Diff" }
        var symbol: String { "plusminus" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
        func title(for key: String) -> String { "cmux" }
    }

    /// Closing the diff: the toast says `Closed "cmux"`, as its tab is titled, not `about:blank`.
    @Test func theCloseToastNamesTheDiff() throws {
        let store = Self.store()
        let pages = InternalPageTabStore()
        pages.register(DiffPage())
        let diff = try #require(store.tab(surface: 3))
        #expect(CloseUndoToasts.title(of: diff, pages: pages) == "cmux")
        let terminal = try #require(store.tab(surface: 2))
        #expect(CloseUndoToasts.title(of: terminal, pages: pages) == CloseUndoToasts.title(of: terminal))
    }
}
