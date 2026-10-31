import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// A Ctrl-` stand-in's terminal, adopted by its daemon tab, shows in the pane that selects that tab (cmux-ad P0
/// 2026-10-31, Lawrence on v2.2.11-opt: "resizing terminals is broken"; his capture: grid 297x87, fit_grid 126x87).
/// The pane selects the daemon tab's node in the selection's turn and asks for its content a frame later; the content
/// request adopted the stand-in's terminal, whose view stayed under the stand-in's node, which that selection hid. The
/// terminal never showed again, so every later size waited for a show (`deferUntilShown`): Ghostty kept its old pixel
/// size while a split's spring still sent the new grid to the PTY. feat-cmux-next has no stand-in adoption.
@MainActor @Suite(.serialized)
struct StandInTerminalNodeTests {
    @Test func theAdoptedTerminalShowsInThePaneThatSelectsItsDaemonTab() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache, store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        // The pane's node (visible), as PaneController.visibilityNode in a shown window and workspace.
        let pane = VisibilityNode(root: "pane", own: .visible)
        var selected: VisibilityNode?
        // PaneController.selectTabNode: the node it shows for the selected tab, and the previous one hidden.
        func select(_ key: String) throws {
            let next = cache.selectedNode(for: key)
            if let shown = selected, shown !== next { shown.set(.hidden) }
            selected = next
            try next.attach(to: pane)
            next.set(.visible)
        }

        // Ctrl-`: the stand-in tab shows in the pane.
        let terminal = TerminalID.generate()
        let standIn = TabModel(ProvisionalTab().terminal(terminal, cwd: nil))
        let entry = cache.terminal(for: standIn, daemon: services.daemon)
        try select(standIn.id)
        let view = entry.session.surfaceView
        #expect(view.visibilityNode.effective == .visible, "the stand-in's terminal does not show in its pane")

        // The daemon's tab arrives in the store; the pane selects it, then asks for its content (showSelectionNow).
        let made = TabSnapshot(surface: SurfaceID(rawValue: 77), tabResourceID: ResourceID(rawValue: "tab_node77"), terminalID: terminal, kind: .pty)
        let paneSnapshot = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [made])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "node-ws"), name: "node",
                              screens: [ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(paneSnapshot.id), panes: [paneSnapshot])]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "node-ws"), index: 0)])
        store.apply(snapshot: tree)
        let daemonTab = try #require(store.tab(terminal: terminal))
        try select(daemonTab.id)
        let adopted = cache.terminal(for: daemonTab, daemon: services.daemon)
        #expect(adopted === entry, "the daemon's tab did not keep the stand-in's terminal")
        #expect(view.visibilityNode.effective == .visible,
                "the adopted terminal is hidden while its pane shows it: every resize waits for a show that never comes")
        cache.release(daemonTab.id)
    }
}
