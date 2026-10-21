@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextWorkspaceNaming
import Testing

/// A page tab dragged to its own workspace is named by the page it shows (Leo 2026-10-20: the
/// What's New tab's workspace was "workspace-42"). `TabMoves.nameInput` reads a page tab as
/// `.page` with the title `InternalPageTabStore.storeTabItem` gives it; this runs the same chain
/// from a store tab whose record title is the `about:blank` placeholder.
@MainActor
struct MovedPageTabWorkspaceNameTests {
    private static func pageTab(_ page: InternalPageID) throws -> TabModel {
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank")
        tab.conversation = ConversationTabRef(page: page.rawValue, route: nil)
        let pane = PaneSnapshot(id: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-42", screens: [screen])]))
        return try #require(store.tab(surface: 1))
    }

    @Test(arguments: [InternalPageID.changelog, .settings])
    func aMovedPageTabNamesItsWorkspaceByItsPage(_ page: InternalPageID) throws {
        let pages = InternalPageTabStore()
        let tab = try Self.pageTab(page)
        #expect(tab.page == page.rawValue)
        let title = try #require(pages.storeTabItem(tab)?.title)
        let input = NewWorkspaceName.Tab(kind: .page, userName: tab.name, title: title, pageTitle: nil, url: nil, cwd: nil)
        let name = NewWorkspaceName.forLastTab(workspaceName: "workspace-42", workspaceTitle: nil, tab: input)
        #expect(name == title)
        if page == .changelog { #expect(name == ChangelogPageStrings.title) }
    }
}
