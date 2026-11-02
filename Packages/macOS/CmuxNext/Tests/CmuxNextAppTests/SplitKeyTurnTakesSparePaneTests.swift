import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE VIDEOS F1 step 1a (STATUS 7221, 7234): a split's key turn was 23-41 ms at 120 Hz, and about 4 ms of each was
/// building the new pane's view tree there (PaneController, PaneContentView, its tab strip, toolbar and their first
/// layout). The window keeps one pane view tree built ahead, out of the window, at rest; the split's key turn takes it.
@Suite(.closesItsWindows)
@MainActor struct SplitKeyTurnTakesSparePaneTests {
    private static func tree(panes: Int) -> DaemonTree {
        let snapshots = (1...panes).map { id in
            PaneSnapshot(id: PaneID(rawValue: UInt64(id)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(id)), title: "~")])
        }
        let layout = snapshots.dropFirst().reduce(LayoutNode.leaf(snapshots[0].id)) { node, pane in
            .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: node, b: .leaf(pane.id))
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: snapshots)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"spare-pane-test","generation":"g1"}"#.utf8))
    }

    @Test func aSplitTakesThePaneViewsBuiltAhead() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(panes: 1))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime((services, state)) { content.teardown(); window.close() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()

        // At rest the window builds its spare pane (the idle refill, run here at once).
        content.refillSparePane()
        let before = Set(content.panes.keys)
        // The split's key turn: the store shows the new pane, the layout mounts it.
        store.apply(snapshot: Self.tree(panes: 2))
        content.applyCurrent()
        let made = content.panes.filter { !before.contains($0.key) }.map(\.value)
        let new = try #require(made.first, "fixture: the split mounted a new pane")
        #expect(new.view.window === window, "the new pane is not in the window")
        #expect(new.view.identifier?.rawValue == "cmux.sparePane",
                "the split's key turn built the new pane's views instead of taking the spare built ahead")
    }
}
