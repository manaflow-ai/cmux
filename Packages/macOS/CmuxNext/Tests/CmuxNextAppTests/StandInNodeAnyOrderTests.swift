import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// A stand-in's content moved to its daemon tab shows when its pane shows that tab, in any order (cmux-ad P0 resize,
/// 2026-10-31, the review of f79664d7e8a: `moveNode` dropped the move when the daemon tab already had a node). Both
/// entry points that move a stand-in's content: a Ctrl-` terminal (`adoptStandIn`) whose daemon tab's node was made
/// before the adoption, and a new browser tab (`moveBrowser`) whose daemon tab the pane selected before the reply.
/// The content stayed under the stand-in's node, which the pane hid: a terminal never resized, a page never showed.
/// feat-cmux-next has neither stand-in adoption nor tab nodes.
@MainActor @Suite(.serialized)
struct StandInNodeAnyOrderTests {
    /// PaneController.selectTabNode: shows `next` in `pane` and hides the node it shows now.
    private static func select(_ next: VisibilityNode, in pane: VisibilityNode, after shown: VisibilityNode?) throws {
        if let shown, shown !== next { shown.set(.hidden) }
        try next.attach(to: pane)
        next.set(.visible)
    }

    @Test func aBrowserStandInsPageShowsWhenThePaneSelectedItsDaemonTabFirst() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache, pane = VisibilityNode(root: "pane", own: .visible)
        let standIn = "pending_tab_browser_standin_1"
        _ = cache.install(MockBrowserEngine().makeMockTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: standIn))), for: standIn)
        let standInNode = cache.node(for: standIn)
        try Self.select(standInNode, in: pane, after: nil)

        // The pane selects the daemon's tab (its node is made now) before the create's reply moves the page.
        let made = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 91), tabResourceID: ResourceID(rawValue: "tab_browser91"), kind: .browser))
        try Self.select(cache.node(for: made.id), in: pane, after: standInNode)
        #expect(cache.moveBrowser(standIn, to: made))
        #expect(standInNode.effective == .visible,
                "the moved page follows the stand-in's node, which the pane hid: it never shows while its tab is selected")
        cache.release(made.id)
    }

    @Test func anAdoptedTerminalShowsWhenItsDaemonTabsNodeWasMadeFirst() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache, pane = VisibilityNode(root: "pane", own: .visible)
        let terminal = TerminalID.generate()
        let standIn = TabModel(ProvisionalTab().terminal(terminal, cwd: nil))
        let entry = cache.terminal(for: standIn, daemon: services.daemon)
        let standInNode = cache.node(for: standIn.id)
        try Self.select(standInNode, in: pane, after: nil)

        // Something else made and holds the daemon tab's node first (`node(for:)`, not the pane's `selectedNode`).
        let made = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 92), tabResourceID: ResourceID(rawValue: "tab_term92"), terminalID: terminal, kind: .pty))
        let first = cache.node(for: made.id)
        try Self.select(first, in: pane, after: standInNode)
        #expect(cache.terminal(for: made, daemon: services.daemon) === entry)
        #expect(entry.session.surfaceView.visibilityNode.effective == .visible,
                "the adopted terminal is hidden while its pane shows its daemon tab: its sizes wait for a show")
        cache.release(made.id)
    }
}
