import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
@testable import CmuxNextApp
@testable import CmuxNextHomeEngine
import CoreGraphics
import Testing

/// Home's pinned dock alone (`pinned-dock-alone-v1`). Leo 2026-10-19: "did we disable the initial
/// thing auto opening a random terminal pane on the right yet?", "i cant even close the terminal on
/// the right of chief", "i cant drag from chief's right side tabs to the left sidebar". Home opens
/// with no right column, its right column closes like any, and the tabs there drag out like any.
@MainActor
struct HomeLoneDockTests {
    private static let homeDock = DockColumn(edge: .left, role: .agentChat, isPinned: true)

    /// Home as the daemon lists it: the pinned chat dock (pane 1, Home's page tab), and, when
    /// `right` is given, a scrolling column (pane 2) holding those tabs.
    private static func home(right: [TabSnapshot]?) -> DaemonStore {
        let store = DaemonStore()
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "Home")
        page.conversation = ConversationTabRef(page: HomeDock.page)
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true)
        var columns = [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1), dock: dock)]
        var panes = [PaneSnapshot(id: 1, tabs: [page])]
        if let right {
            columns.append(ColumnSnapshot(id: 11, width: 0.5, layout: .leaf(2)))
            panes.append(PaneSnapshot(id: 2, tabs: right))
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
        var workspace = WorkspaceSnapshot(id: 1, key: nil, name: "Home", screens: [screen])
        workspace.kind = "home"
        store.apply(snapshot: DaemonTree(workspaces: [workspace]))
        return store
    }

    private static func shell(_ surface: SurfaceID, cwd: String? = "/Users/me", title: String = "~") -> TabSnapshot {
        var tab = TabSnapshot(surface: surface, kind: .pty, title: title)
        tab.cwd = cwd
        return tab
    }

    /// Alone, the dock fills the screen (it is the strip's one column) and keeps its own width for
    /// when a column opens beside it.
    @Test func aLoneDockFillsTheScreen() {
        let lone = LayoutColumn(id: "home", width: 0.5, root: .leaf("dock"), dock: Self.homeDock)
        let parts = DockStripGeometry.docks([lone])
        #expect(parts.left == nil)
        #expect(parts.scrolling.map(\.width) == [1])
        let beside = DockStripGeometry.docks([lone, LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))])
        #expect(beside.left?.width == 0.5, "with a column beside it the dock is a dock again")
    }

    /// A person's new tab, and a new chat, from the dock alone open in a new column right of it:
    /// the pinned dock takes neither, and there is no scrolling pane to send them to.
    @Test func newTabsFromTheLoneDockOpenBesideIt() {
        let lone = [LayoutColumn(id: "home", root: .leaf("dock"), dock: Self.homeDock)]
        #expect(ChatColumnPlacement.resolve(from: "dock", columns: lone) { _ in false } == .besideDock)
        #expect(NewChatPlacement.resolve(from: "dock", columns: lone, isLoneChat: false) == .besideDock)
        // A chat dock that takes tabs keeps them, alone or not.
        let open = [LayoutColumn(id: "home", root: .leaf("dock"),
                                 dock: DockColumn(edge: .left, role: .agentChat, isPinned: true, allowsTabs: true))]
        #expect(ChatColumnPlacement.resolve(from: "dock", columns: open) { _ in false } == .here)
        #expect(NewChatPlacement.resolve(from: "dock", columns: open, isLoneChat: false) == .dock("dock"))
        // With a column beside it, the strip takes them as before.
        let beside = lone + [LayoutColumn(id: "c1", root: .leaf("p1"))]
        #expect(ChatColumnPlacement.resolve(from: "dock", columns: beside) { _ in false } == .tab(in: "p1"))
    }

    /// Only Home's own tab stays in Home: a tab right of its dock moves to a new workspace (a sidebar
    /// drop) or a new window like any tab, by drag, menu or palette.
    @Test func onlyHomesOwnTabStaysInHome() throws {
        let store = Self.home(right: [Self.shell(2), TabSnapshot(surface: 3, kind: .browser, title: "Docs")])
        let home = try #require(store.workspaces.first)
        let page = try #require(store.tab(surface: 1)), right = try #require(store.tab(surface: 3))
        #expect(TabPromotion.staysPut(tab: page.id, in: home))
        #expect(!TabPromotion.staysPut(tab: right.id, in: home))
        #expect(TabPromotion.menuRemovals(keepsTab: false).isEmpty)
        var context = TabDragContext(sourcePaneID: "2", sourcePaneTabCount: 2, sourceWorkspaceID: home.id,
                                     sourceWorkspaceTabCount: 3, draggedTabCount: 1)
        context.sourceStaysPut = TabPromotion.staysPut(tab: right.id, in: home)
        #expect(TabDragResolver.verdict(.newWorkspace(groupID: nil, index: 0), context: context) == .accept)
        context.sourceStaysPut = TabPromotion.staysPut(tab: page.id, in: home)
        #expect(TabDragResolver.verdict(.newWorkspace(groupID: nil, index: 0), context: context) == .refuse(.staysPut))
    }

    /// A Home restored from before keeps the shell the dock move left on its right only while it is
    /// real: a used terminal, or anything else, stays; the untouched shell at `~` closes.
    @Test func theRestoredPlaceholderShellIsTheOnlyRightTabThatCloses() throws {
        let home = "/Users/me"
        func placeholder(_ right: [TabSnapshot]?) throws -> SurfaceID? {
            let store = Self.home(right: right)
            let screen = try #require(store.workspaces.first?.screens.first)
            return HomeDock.placeholderShell(on: screen, home: home)?.surface
        }
        #expect(try placeholder([Self.shell(2)]) == 2)
        #expect(try placeholder([Self.shell(2, cwd: nil, title: "")]) == 2)
        #expect(try placeholder([Self.shell(2, cwd: "/Users/me/src/cmux", title: "cmux")]) == nil, "a shell moved on is real")
        #expect(try placeholder([Self.shell(2), Self.shell(3)]) == nil, "two tabs are the person's")
        #expect(try placeholder([TabSnapshot(surface: 2, kind: .browser, title: "~")]) == nil)
        var named = Self.shell(2)
        named.name = "server"
        #expect(try placeholder([named]) == nil)
        var dead = Self.shell(2)
        dead.dead = true
        #expect(try placeholder([dead]) == nil)
        #expect(try placeholder(nil) == nil, "a lone dock has nothing to close")
    }
}
