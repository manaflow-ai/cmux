import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE VIDEOS F1 step (c'): a pane controller's strip setup that does not depend on its pane (the + and its type
/// chooser, the hover cards, previews and resources) set in a split's key turn ran a strip token pass and a layout of the
/// strip there (5 to 8 ms of 32 in the (b)+(c) profiles). The spare built at rest has that setup already, and the
/// controller that takes the spare does not set it again.
@Suite(.closesItsWindows)
@MainActor struct SparePaneStripIsSetUpAtRestTests {
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

    @Test func theSpareComesWithItsStripSetUp() throws {
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

        content.refillSparePane()
        let strip = try #require(content.sparePane?.view.stripView)
        #expect(strip.showsNewTabMenuButton, "the spare's strip has no pane-type chooser until the split's key turn")
        #expect(!strip.opensNewTabMenuOnPress)
        #expect(strip.previewProvider === services.previews, "the spare's strip has no previews until the split's key turn")
        #expect(strip.hoverCards === services.hoverCards)
    }
}
