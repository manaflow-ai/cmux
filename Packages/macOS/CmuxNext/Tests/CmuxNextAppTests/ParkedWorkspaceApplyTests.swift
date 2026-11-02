import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// A workspace parked off screen (its window shows another one) updates its model only: a split,
/// a new column or a pane move that a script makes there causes no layout apply, no view sync and
/// no focus topology. When it shows, one apply takes it straight to the final state (CLAUDE.md
/// "Go past Chrome where cmux is scripted": background workspaces cost nothing until shown).
@Suite(.closesItsWindows)
@MainActor struct ParkedWorkspaceApplyTests {
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
        let json = #"{"app":"cmux-tui","protocol":1,"session":"parked-apply-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    @Test func aParkedWorkspaceAppliesItsTreeOnceWhenShown() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(panes: 1))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The controller holds its window state unowned: the test keeps it alive, as its window does.
        let state = WindowState(record: record)
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime((services, state)) { content.teardown(); window.close() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        content.contentView.layoutSubtreeIfNeeded()
        #expect(content.layoutModel.screens.first?.layout.panes.count == 1)

        content.contentView.isHidden = true
        content.park(serial: 1)
        // This controller's own counts: the process-wide ones also count the workspaces of tests that
        // run while this one yields (`settle`).
        let applies = content.debugApplies, topologies = content.debugTopologySends
        // A script splits the parked workspace three times.
        for panes in 2...4 {
            store.apply(snapshot: Self.tree(panes: panes))
            await Self.settle()
        }
        #expect(content.debugApplies - applies == 0, "a parked workspace laid out a change nobody sees")
        #expect(content.debugTopologySends - topologies == 0, "a parked workspace sent a focus topology")
        #expect(content.layoutModel.screens.first?.layout.panes.count == 1, "the parked layout moved while off screen")

        content.unpark()
        content.contentView.isHidden = false
        #expect(content.debugApplies - applies == 1, "showing it did not apply its final tree in one step")
        #expect(content.layoutModel.screens.first?.layout.panes.count == 4, "the shown workspace is not at its final tree")
    }
}
