import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE VIDEOS F1 step (c): the spare pane built at rest waits inside the window, under a container that clips it to
/// nothing, so its layers are made, drawn and sent to the render server at idle. The split's key turn then only moves
/// it into its host and sets its frame: no new layer and no first draw of its subtree in the key's commit.
@Suite(.closesItsWindows)
@MainActor struct SparePaneWaitsInTheWindowTests {
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

    private static func layers(of view: NSView) -> [ObjectIdentifier] {
        (view.layer.map { [ObjectIdentifier($0)] } ?? []) + view.subviews.flatMap { layers(of: $0) }
    }

    @Test func theSpareWaitsInTheWindowUnseenAndTheSplitKeepsItsLayers() throws {
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
        let spare = try #require(content.sparePane?.view)
        #expect(spare.window === window, "the spare pane waits out of the window: its layers are made in the split's commit")
        #expect(!spare.isHiddenOrHasHiddenAncestor, "a hidden spare draws nothing at idle")
        let visible = spare.superview.map { $0.convert($0.bounds, to: nil) } ?? .zero
        #expect(visible.width * visible.height == 0, "the spare pane shows in the window")
        let grid = stride(from: 5, to: 1200, by: 50).flatMap { x in stride(from: 5, to: 700, by: 50).map { CGPoint(x: x, y: $0) } }
        #expect(grid.allSatisfy { content.contentView.hitTest($0).map { !$0.isDescendant(of: spare) } ?? true },
                "a click reaches the spare pane")
        let before = Set(Self.layers(of: spare))

        let mounted = Set(content.panes.keys)
        store.apply(snapshot: Self.tree(panes: 2))
        content.applyCurrent()
        let new = try #require(content.panes.first { !mounted.contains($0.key) }?.value, "fixture: the split mounted a new pane")
        #expect(new.view === spare, "fixture: the split took the spare")
        #expect(before.isSubset(of: Set(Self.layers(of: new.view))), "the split's key turn made the spare's layers again")
    }
}
