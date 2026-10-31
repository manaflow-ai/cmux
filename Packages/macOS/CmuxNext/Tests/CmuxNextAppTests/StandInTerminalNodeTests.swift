import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// A Ctrl-` stand-in's terminal, adopted by its daemon tab, follows the node the pane shows for that tab
/// (cmux-ad P0 2026-10-31, Lawrence on v2.2.11-opt: "resizing terminals is broken"; his capture: grid 297x87, fit_grid
/// 126x87). The pane selects the daemon tab (and makes its node) before it asks for the tab's content, which adopts the
/// stand-in's terminal. The adopted view kept the stand-in's node, which that selection had hidden: the terminal was
/// never "shown" again, so every later size waited for a show that never came, and Ghostty kept its old pixel size
/// while a split's spring still sent the new grid to the PTY.
@MainActor @Suite(.serialized)
struct StandInTerminalNodeTests {
    @Test func theAdoptedTerminalFollowsTheNodeThePaneShowsForItsDaemonTab() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        // The pane's node (visible), as PaneController.visibilityNode under a shown window and workspace.
        let pane = VisibilityNode(root: "pane", own: .visible)

        // Ctrl-`: the stand-in tab shows in the pane.
        let terminal = TerminalID.generate()
        let standIn = TabModel(ProvisionalTab().terminal(terminal, cwd: nil))
        let entry = cache.terminal(for: standIn, daemon: services.daemon)
        let standInNode = cache.node(for: standIn.id)
        try standInNode.attach(to: pane)
        standInNode.set(.visible)
        let view = entry.session.surfaceView
        #expect(view.visibilityNode.effective == .visible, "the stand-in's terminal does not show in its pane")

        // The daemon's tab arrives: the pane selects it first (PaneController.selectTabNode), which makes its node,
        // shows it and hides the stand-in's node.
        let made = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 77), tabResourceID: ResourceID(rawValue: "tab_node77"),
                                        terminalID: terminal, kind: .pty))
        let selected = cache.node(for: made.id)
        try selected.attach(to: pane)
        selected.set(.visible)
        standInNode.set(.hidden)

        // Then it asks for the tab's content (showSelectionNow): the daemon's tab adopts the stand-in's terminal.
        let adopted = cache.terminal(for: made, daemon: services.daemon)
        #expect(adopted === entry)

        // The node the pane shows for the daemon tab after its content came (showSelectionNow selects it again) is
        // the one the adopted terminal follows, so the terminal shows and takes its sizes.
        let shown = cache.node(for: made.id)
        try shown.attach(to: pane)
        shown.set(.visible)
        #expect(view.visibilityNode.parent === shown,
                "the adopted terminal follows the stand-in's node, not the node its pane shows for the daemon tab")
        #expect(view.visibilityNode.effective == .visible,
                "the adopted terminal is hidden while its pane shows it: its sizes wait for a show that never comes")
        cache.release(made.id)
    }
}
