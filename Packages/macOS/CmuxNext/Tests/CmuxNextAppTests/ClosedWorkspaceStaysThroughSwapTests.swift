import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-15: "it should be instant even under load". Closing the shown workspace shows the next one in the
/// press's turn, and the window keeps the closing one on screen while the next one has not drawn (`PanePaintHold`).
/// When the daemon's close then arrived, the window tore the closing workspace's controller down at once: its view
/// left the window under the hold, and the window showed nothing (the next workspace still unseen) until that one drew.
/// The view now leaves with the swap, in the frame the next workspace shows.
@Suite(.serialized, .closesItsWindows)
@MainActor struct ClosedWorkspaceStaysThroughSwapTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"closed-stays-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func aClosedWorkspaceTornDownDuringTheSwapStaysUntilTheNextOneDrew() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let closing = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { withExtendedLifetime((services, state)) { closing.teardown(); window.close() } }

        // The next workspace, parked at the old size: shown at the new one, it waits until its chat drew there.
        let page = WorkspaceSwitchRedrawHoldTests.DrawnPage()
        let next = WorkspaceSwitchRedrawHoldTests.workspace(page)
        WorkspaceSwitchRedrawHoldTests.show(next, in: root)
        root.show(closing.contentView)
        WorkspaceSwitchRedrawHoldTests.settle(root)
        window.setContentSize(NSSize(width: 1240, height: 700))
        root.layoutSubtreeIfNeeded()
        root.show(next) // the close's turn: the next workspace shows
        try #require(next.alphaValue == 0 && !closing.contentView.isHidden, "fixture: the window keeps the closing workspace")

        closing.teardown() // the daemon's close arrived: the window lets the closing workspace's controller go
        #expect(closing.contentView.superview === root.contentHost && !closing.contentView.isHidden,
                "the closing workspace left the window while the next one was unseen: an empty frame")
        page.redraw()
        #expect(next.alphaValue == 1)
        #expect(closing.contentView.superview == nil, "the closed workspace's view stayed after the swap")
    }
}
