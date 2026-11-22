import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// A pane that closes as a whole leaves in the key's frame (`showPaneClose`), and the daemon's echo
/// then applies the tree without it: one workspace apply and one focus topology per close. The key's
/// turn redraws the layout from its model and does not apply the unchanged store tree again: that
/// forced apply rebuilt the whole focus topology (O(N)) a second time, and the perf gate's split
/// scenario measured 3 applies and 3 topology sends per split+close pair against its budget of 2
/// (bca04e862d8d, scripts/cmux-next/perf-gate.py).
@Suite(.closesItsWindows)
@MainActor struct PaneCloseApplyTests {
    private static func tree(split: Bool) -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = split
            ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
            : .leaf(first.id)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: split ? [first, second] : [first])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"pane-close-apply-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The two-pane workspace shown in a borderless window, laid out.
    private static func shown() throws -> (AppServices, NSWindow, WorkspaceContentController, [LayoutPaneID]) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(split: true))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let panes = try #require(content.layoutModel.screens.first?.layout.panes)
        try #require(panes.count == 2)
        return (services, window, content, panes)
    }

    @Test func aPaneCloseShowsInTheKeysFrameWithNoApplyOrTopologyOfItsOwn() throws {
        let (services, window, content, panes) = try Self.shown()
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let closing = try #require(content.paneController(key: panes[1].rawValue))

        let applies = DebugLayoutCounters.workspaceApplies, topologies = DebugLayoutCounters.topologySends
        let close = closing.showPaneClose()

        #expect(close != nil, "a pane beside another closes in the key's frame")
        #expect(DebugLayoutCounters.workspaceApplies - applies == 0, "the key's turn applied the unchanged store tree again")
        #expect(DebugLayoutCounters.topologySends - topologies == 0, "the key's turn rebuilt the focus topology; the daemon's echo sends it")
        // The pane still leaves in this frame: the model shows one pane and the view mirrors it.
        #expect(content.layoutModel.screens.first?.layout.panes == [panes[0]], "the closing pane is still shown")
        let drawn = content.layoutView.overlayRings.map(\.pane)
        #expect(drawn == [panes[0].rawValue], "the closing pane is still drawn in the key's frame: \(drawn)")
    }

    /// A CLI, script or agent close of the focused pane may not move the view, so the coordinator
    /// refuses the successor's focus: the topology without the pane still moves the focus off it in
    /// the key's turn, so keys never go to a pane that left.
    @Test func aRunThatMayNotMoveTheViewStillTakesTheFocusOffTheClosingPane() throws {
        let (services, window, content, panes) = try Self.shown()
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        content.focus.send(.focusPane(panes[1].rawValue, source: .programmatic))
        try #require(content.focus.state.pane == panes[1].rawValue)
        let closing = try #require(content.paneController(key: panes[1].rawValue))

        let close = ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            closing.showPaneClose()
        }

        #expect(close != nil)
        #expect(content.focus.state.pane == panes[0].rawValue, "the focus stayed on the closing pane: \(String(describing: content.focus.state.pane))")
    }
}
