import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTabs
import Foundation
import Testing

/// A workspace its window unmounts (parked, then torn down to free memory, or its window closed)
/// leaves no app object behind (p07-memory-034, MQ-LEAK classes Workspace|Pane|Strip|Tab|Layout):
/// after `teardown` and one main-actor turn, the content controller, its layout and content views,
/// its screen bar strip, every pane controller and every pane's tab strip are freed. A tree change
/// or a repair that lands after the teardown mounts no pane again.
@MainActor struct UnmountedWorkspaceLeavesNoObjectsTests {
    /// Weak references to everything one mounted workspace made.
    final class Probes {
        /// The window's one strong reference (`WindowController.parked`).
        var parked: WorkspaceContentController?
        weak var content: WorkspaceContentController?
        weak var layoutView: LayoutRootView?
        weak var contentView: WorkspaceContentView?
        weak var screenBarStrip: TabStripView?
        var panes: [Weak<PaneController>] = []
        var strips: [Weak<TabStripView>] = []

        /// The names of the probes still alive.
        var alive: [String] {
            var names: [String] = []
            if content != nil { names.append("WorkspaceContentController") }
            if layoutView != nil { names.append("LayoutRootView") }
            if contentView != nil { names.append("WorkspaceContentView") }
            if screenBarStrip != nil { names.append("screen bar TabStripView") }
            names += panes.compactMap(\.object).map { "PaneController \($0.paneKey)" }
            names += strips.filter { $0.object != nil }.map { _ in "pane TabStripView" }
            return names
        }
    }

    struct Weak<Object: AnyObject> {
        weak var object: Object?
    }

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
        let json = #"{"app":"cmux-tui","protocol":1,"session":"unmounted-workspace-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// One main-actor turn: the cancelled observation tasks and the focus coordinator's queued
    /// reduction run. A fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private struct World {
        let services: AppServices
        let state: WindowState
        let window: NSWindow
        let host: NSView
        let workspace: WorkspaceModel
    }

    private static func world(split: Bool) throws -> World {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try connected())
        store.apply(snapshot: tree(split: split))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The window root holds workspace content views as subviews, as `WindowRootView` does.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        window.contentView = host
        window.orderFrontRegardless()
        return World(services: services, state: WindowState(record: record), window: window, host: host, workspace: workspace)
    }

    /// Mounts the workspace in `world`'s window with both panes, parks it (its window showed
    /// another), and returns weak references to what it made. Only `Probes.parked` holds it.
    private static func mountAndPark(in world: World) throws -> Probes {
        let probes = Probes()
        try autoreleasepool {
            let content = WorkspaceContentController(workspace: world.workspace, daemon: world.services.daemon,
                                                     services: world.services, state: world.state)
            content.contentView.frame = world.host.bounds
            world.host.addSubview(content.contentView)
            content.applyCurrent()
            content.didShow()
            content.contentView.layoutSubtreeIfNeeded()
            try #require(content.panes.count == 2, "both panes mount")
            probes.content = content
            probes.layoutView = content.layoutView
            probes.contentView = content.contentView
            probes.screenBarStrip = content.screenBar.view
            probes.panes = content.panes.values.map { Weak(object: $0) }
            probes.strips = content.panes.values.map { Weak(object: $0.view.stripView) }
            content.park(serial: 1)
            probes.parked = content
        }
        return probes
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnmountedWorkspaceFreesItsControllerViewsPanesAndStrips() async throws {
        let world = try Self.world(split: true)
        defer { withExtendedLifetime(world.services) { world.window.close() } }
        let probes = try Self.mountAndPark(in: world)
        await Self.drainMain()
        #expect(probes.alive.count == 8, "everything the workspace made is alive while it is mounted: \(probes.alive)")

        // The window's unmount: teardown, then it drops its reference (`WindowController.parked`).
        autoreleasepool {
            probes.parked?.teardown()
            probes.parked = nil
        }
        await Self.drainMain()
        #expect(probes.alive.isEmpty, "alive after teardown and one turn: \(probes.alive)")
    }

    @Test(.timeLimit(.minutes(1)))
    func aTreeChangeOrRepairAfterTeardownMountsNoPane() async throws {
        let world = try Self.world(split: false)
        defer { withExtendedLifetime(world.services) { world.window.close() } }
        let content = WorkspaceContentController(workspace: world.workspace, daemon: world.services.daemon,
                                                 services: world.services, state: world.state)
        content.contentView.frame = world.host.bounds
        world.host.addSubview(content.contentView)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        #expect(content.panes.count == 1)

        content.teardown()
        #expect(content.panes.isEmpty)
        #expect(content.contentView.superview == nil, "the torn-down content left the window")
        let mounts = world.services.paneMounts.generation
        // The daemon's split lands after the teardown, then a command response re-applies and the
        // window unparks it by mistake: none of them mounts a pane or restarts an observation.
        world.services.daemon.store.apply(snapshot: Self.tree(split: true))
        await Self.drainMain()
        content.applyCurrent()
        content.unpark()
        content.didShow()
        content.contentView.layoutSubtreeIfNeeded()
        #expect(content.panes.isEmpty, "a change after teardown mounted \(content.panes.count) panes")
        #expect(world.services.paneMounts.generation == mounts, "a pane mounted or released after teardown")
        content.teardown() // idempotent
        #expect(world.services.paneMounts.generation == mounts)
    }
}
