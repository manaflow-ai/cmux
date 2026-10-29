import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTabs
@testable import CmuxNextWorkspaceRepair
import Foundation
import Testing

/// A workspace its window unmounts (parked, then torn down to free memory, or its window closed)
/// leaves no app object behind (MQ-LEAK classes Workspace|Pane|Strip|Tab|Layout):
/// after `teardown` and one main-actor turn, the content controller, its layout and content views,
/// its screen bar strip, every pane controller and every pane's tab strip are freed. A tree change
/// or a repair that lands after the teardown mounts no pane and asks the window for no focus, and
/// no topology of it stays queued in the window's focus coordinator.
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

    /// A flag a test closure sets (the repair's create runs in its own task).
    final class Flag {
        var value = false
    }

    private static var key: WorkspaceKey { WorkspaceKey(rawValue: "w1") }

    /// The workspace with no pane: its terminal was lost.
    private static var emptied: DaemonTree {
        DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "w1", screens: [])])
    }

    private static func tree(split: Bool) -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = split
            ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
            : .leaf(first.id)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: split ? [first, second] : [first])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "w1", screens: [screen])])
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
    func aTreeChangeAfterTeardownMountsNoPane() async throws {
        let world = try Self.world(split: false)
        defer { withExtendedLifetime(world.services) { world.window.close() } }
        let content = WorkspaceContentController(workspace: world.workspace, daemon: world.services.daemon,
                                                 services: world.services, state: world.state)
        content.contentView.frame = world.host.bounds
        world.host.addSubview(content.contentView)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        #expect(content.panes.count == 1)

        let mounted = world.services.paneMounts.generation
        content.teardown()
        #expect(content.panes.isEmpty)
        #expect(content.contentView.superview == nil, "the torn-down content left the window")
        let mounts = world.services.paneMounts.generation
        #expect(mounts != mounted, "the released panes tell the pane readers, as releaseContentView does")
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

    /// The repair of a lost terminal (`emptyWorkspaceRepair.check`) was asked while the workspace
    /// was mounted and answers after its teardown, while something still holds the content (a
    /// create's task did before): its new terminal mounts no pane and leaves no focus expectation
    /// in the window's coordinator, which would take focus from the next workspace shown.
    @Test(.timeLimit(.minutes(1)))
    func aRepairThatLandsAfterTeardownMountsNoPaneAndExpectsNoFocus() async throws {
        let world = try Self.world(split: false)
        defer { withExtendedLifetime(world.services) { world.window.close() } }
        let store = world.services.daemon.store
        let repair = world.services.emptyWorkspaces
        repair.canCreate = { true }
        repair.isLive = { false } // the first pass sees the pane on no live connection: no close later
        // The repair's follows start in a turn it posted, after these seams: its first
        // membership pass examines the workspace with them.
        #expect(repair.visited == 0, "the repair's first pass ran in its init's turn, before the test's seams")
        try #require(runMainLoop { repair.visited == 1 }, "the repair's posted start did not run its first pass")
        repair.isLive = { true }
        let (gate, open) = AsyncStream<Void>.makeStream()
        let asked = Flag(), answered = Flag()
        repair.create = { _ in
            asked.value = true
            for await _ in gate { break }
            store.apply(snapshot: Self.tree(split: false)) // the new terminal reaches the store first
            answered.value = true
            return SurfaceID(rawValue: 1)
        }
        store.apply(snapshot: Self.emptied)
        // The pane follow's flush examines it: emptied, but never seen with a pane on a live connection, so not claimed.
        _ = runMainLoop { repair.visited >= 2 }
        #expect(!repair.isSettling(Self.key), "the emptied workspace was claimed before the window asked")

        let content = WorkspaceContentController(workspace: world.workspace, daemon: world.services.daemon,
                                                 services: world.services, state: world.state)
        content.contentView.frame = world.host.bounds
        world.host.addSubview(content.contentView)
        content.applyCurrent()
        content.didShow()
        // The create runs from a task off main (recipe R-hop), so its first step comes some turns later.
        try #require(runMainLoop { asked.value }, "the empty workspace asked for a new terminal")
        // The window's check asked (`createTab` with its `created`), not a close decision's refill without one.
        #expect(repair.decisions.isEmpty, "the repair decided \(repair.decisions.map { $0.cause }) instead of the window's check asking")
        #expect(content.panes.isEmpty)

        content.teardown()
        let mounts = world.services.paneMounts.generation
        open.yield(())
        try #require(runMainLoop { answered.value }, "the repair answered")
        // The create's answer reaches main as a posted task, which runs the window's `created` after the teardown.
        try #require(runMainLoop { repair.answeredCreates == 1 }, "the window's created never ran after the teardown")
        #expect(content.panes.isEmpty, "a repair after teardown mounted \(content.panes.count) panes")
        #expect(world.services.paneMounts.generation == mounts, "a pane mounted after teardown")
        #expect(world.state.focus.state.expectation == nil, "a torn-down workspace left a focus expectation")
        open.finish()
    }

    /// A topology a pane queued (`setNeedsTopology`) before the teardown leaves the coordinator with
    /// it: the coordinator keys it by object identity, which a later content can reuse, and would
    /// then drop that content's own topology as a duplicate. A pane's late change queues none.
    @Test(.timeLimit(.minutes(1)))
    func aTopologyQueuedBeforeTeardownLeavesTheCoordinator() throws {
        let world = try Self.world(split: false)
        defer { withExtendedLifetime(world.services) { world.window.close() } }
        let content = WorkspaceContentController(workspace: world.workspace, daemon: world.services.daemon,
                                                 services: world.services, state: world.state)
        content.contentView.frame = world.host.bounds
        world.host.addSubview(content.contentView)
        content.applyCurrent()
        let focus = world.state.focus
        content.setNeedsTopology()
        try #require(focus.hasPendingTopology(for: content), "a pane's change queues the content's topology")

        content.teardown()
        #expect(!focus.hasPendingTopology(for: content), "the torn-down content's topology stayed queued")
        content.setNeedsTopology()
        #expect(!focus.hasPendingTopology(for: content), "a torn-down content queued a topology")
    }
}
