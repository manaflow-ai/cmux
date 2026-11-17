import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import Foundation
import Testing

// CmuxNextLayout has its own PaneID and ScreenID; the daemon tree takes the daemon's.
private typealias DaemonPaneID = CmuxNextDaemon.PaneID
private typealias DaemonScreenID = CmuxNextDaemon.ScreenID

/// Toggle Pane Zoom and the Swap Pane actions change the screen in the turn of their key: the store shows the change
/// as an intent, the window's layout model and view take it in the same turn, and the daemon's answer only confirms it
/// (plans/cmux-next/zero-latency.md, "Native actions: the budget contract"). Before, both waited for the daemon's
/// `layout-changed` event (zoom: 50 to 60 ms from the key to the first change).
///
/// The app has a connection that never becomes ready, so no answer ever comes while a handler's turn is checked and
/// every command is then refused (`DaemonError.notConnected`): the answer is held back, and the refusal is real.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct PaneVerbsKeyTurnTests {
    private static let left = DaemonPaneID(rawValue: 1), right = DaemonPaneID(rawValue: 2), below = DaemonPaneID(rawValue: 3)
    private static let screen = DaemonScreenID(rawValue: 1)
    private static let workspace = "key-turn-ws"

    private static func split(_ a: DaemonPaneID, _ b: DaemonPaneID) -> LayoutNode {
        .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(a), b: .leaf(b))
    }

    /// `left` beside a column of `top` (the larger part) over `bottom`.
    private static func three(_ left: DaemonPaneID, _ top: DaemonPaneID, _ bottom: DaemonPaneID) -> LayoutNode {
        .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(left),
               b: .split(id: nil, resourceID: nil, direction: .down, ratio: 0.6, a: .leaf(top), b: .leaf(bottom)))
    }

    private static func tree(_ layout: LayoutNode) -> DaemonTree {
        let panes = layout.paneIDs.map { PaneSnapshot(id: $0, tabs: [TabSnapshot(surface: SurfaceID(rawValue: $0.rawValue), title: "~")]) }
        let screen = ScreenSnapshot(id: screen, active: true, activePane: left, layout: layout, panes: panes)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: workspace), name: "key turn", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: workspace), index: 0)])
        return tree
    }

    private struct Shown {
        let services: AppServices
        let controller: WindowController
        let content: WorkspaceContentController
        /// Daemon pane 1, on the left, and daemon pane 2, on the right.
        let left: PaneController
        let right: PaneController

        var store: DaemonStore { services.daemon.store }
        /// The panes of the shown screen in layout order, as daemon handles.
        var order: [DaemonPaneID] {
            (content.layoutModel.screens.first?.layout.panes ?? []).compactMap { content.handles.panes[$0] }
        }
        var zoomed: Bool { content.layoutModel.screens.first?.zoomed ?? false }
        /// Where the layout view puts `pane` (the geometry its motion heads for).
        func frame(_ pane: PaneController) -> CGRect? {
            content.layoutView.navigationFrames(ofScreenContaining: pane.layoutPaneID)[pane.layoutPaneID]
        }

        func close() {
            controller.teardown()
            controller.window?.close()
            services.daemon.shutdownConnection()
        }
    }

    /// The app with one window showing a two-pane split, and a daemon connection that never answers.
    private static func shown() async throws -> Shown {
        let shown = try await shown(split(left, right))
        // The harness: the view laid the two panes out side by side, the left one first.
        let a = try #require(shown.frame(shown.left), "the layout view has no frame for the left pane")
        let b = try #require(shown.frame(shown.right), "the layout view has no frame for the right pane")
        try #require(a.width > 100 && a.maxX <= b.minX, "the two panes are not side by side: \(a) \(b)")
        try #require(shown.order == [left, right] && !shown.zoomed)
        return shown
    }

    /// The app with one window showing `layout` (pane 1 on the left, pane 2 on its right), and a daemon connection
    /// that never answers.
    private static func shown(_ layout: LayoutNode) async throws -> Shown {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-key-turn-\(UUID().uuidString).sock"))
        services.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
        await services.daemon.firstConnection()
        try #require(services.daemon.connection != nil, "the service never took the connection")
        let store = services.daemon.store
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(layout))
        let count = layout.paneIDs.count
        let controller = try #require(services.windows.openWindow(workspaces: [workspace], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        // test-wait: the window shows the workspace's panes once its content controller builds them.
        for _ in 0..<200 where controller.workspaceContent?.panes.count != count { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == count, "the window never showed the workspace's \(count) panes")
        content.contentView.layoutSubtreeIfNeeded()
        let first = try #require(content.panes.values.first { $0.pane.handle == left })
        let second = try #require(content.panes.values.first { $0.pane.handle == right })
        PaneHandlers.focus(first.layoutPaneID, in: content)
        return Shown(services: services, controller: controller, content: content, left: first, right: second)
    }

    private static func run(_ id: ActionID, on pane: PaneController, _ shown: Shown) -> Bool {
        shown.services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), origin: .user))
    }

    /// Test-harness poll for work on other tasks; the limit is only a failure deadline.
    private static func eventually(_ done: () -> Bool) async -> Bool {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        return done()
    }

    // MARK: (a) zoom

    @Test func zoomShowsInTheTurnOfItsKeyAndUnzoomIsItsInverse() async throws {
        let shown = try await Self.shown()
        defer { shown.close() }
        let before = try #require(shown.frame(shown.left))

        // One main-actor turn, no await: the daemon cannot have answered.
        #expect(Self.run("toggleSplitZoom", on: shown.left, shown))
        #expect(shown.zoomed, "the layout model is not zoomed when the zoom action's handler returns")
        #expect(shown.order == [Self.left], "the zoomed screen does not show its zoomed pane alone: \(shown.order)")
        #expect(shown.store.screen(containing: Self.left)?.zoomedPane == Self.left, "the store does not show the zoom")
        let after = shown.frame(shown.left)
        #expect((after?.width ?? 0) > before.width + 100, "the layout view did not start the zoom in the key's turn: \(String(describing: after)), was \(before)")

        // The inverse, also before any answer: the screen is back as it was.
        #expect(Self.run("toggleSplitZoom", on: shown.left, shown))
        #expect(!shown.zoomed, "the layout model is still zoomed when the unzoom action's handler returns")
        #expect(shown.order == [Self.left, Self.right], "the unzoom did not bring the panes back: \(shown.order)")
        #expect(shown.store.screen(containing: Self.left)?.zoomedPane == nil)
        #expect(shown.frame(shown.left)?.width == before.width, "the unzoomed pane does not head for its old frame")
    }

    // MARK: (b) swap

    @Test(arguments: ["swapPaneRight", "swapPaneLeft"])
    func aDirectionalSwapShowsInTheTurnOfItsKey(action: String) async throws {
        let shown = try await Self.shown()
        defer { shown.close() }
        let source = action == "swapPaneRight" ? shown.left : shown.right
        let leftFrame = try #require(shown.frame(shown.left)), rightFrame = try #require(shown.frame(shown.right))

        #expect(Self.run(ActionID(rawValue: action), on: source, shown))
        #expect(shown.order == [Self.right, Self.left], "the two panes have not changed places when the swap action's handler returns: \(shown.order)")
        #expect(shown.store.screen(containing: Self.left)?.layout == Self.split(Self.right, Self.left), "the store does not show the swap")
        #expect(shown.frame(shown.left) == rightFrame && shown.frame(shown.right) == leftFrame,
                "the layout view did not move the panes in the key's turn: \(String(describing: shown.frame(shown.left))) \(String(describing: shown.frame(shown.right)))")
        #expect(!shown.zoomed)
    }

    @Test func swapWithANamedPaneShowsInTheTurnOfItsRun() async throws {
        let shown = try await Self.shown()
        defer { shown.close() }
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: shown.left.paneKey), origin: .user)
        invocation.arguments["pane"] = .target(ActionTargetRef(kind: .pane, id: shown.right.pane.id))

        #expect(shown.services.registry.perform("palette.swapWithSession", invocation: invocation))
        #expect(shown.order == [Self.right, Self.left], "the two panes have not changed places when the handler returns: \(shown.order)")
    }

    /// The case where the app's rule and the daemon's direction rule name two panes: on the right of the left pane
    /// are a larger pane and a smaller one, and the person was last in the smaller one. Focus Pane Right goes to the
    /// smaller one (the most recently focused of the adjacent panes); `swap-pane` with `dir` takes the larger one
    /// (cmux-tui's `directional_neighbor`: the largest overlap, no focus history). The app sends `target`, so the
    /// daemon exchanges the two panes the screen shows exchanged: its event changes nothing and swaps nothing back.
    @Test func aDirectionalSwapTakesFocusPanesNeighborAndTheDaemonsEchoAgrees() async throws {
        let shown = try await Self.shown(Self.three(Self.left, Self.right, Self.below))
        defer { shown.close() }
        let smaller = try #require(shown.content.panes.values.first { $0.pane.handle == Self.below })
        let before = try #require(shown.frame(smaller))
        try #require(before.height < (shown.frame(shown.right)?.height ?? 0), "the lower pane is not the smaller one: \(before)")
        PaneHandlers.focus(smaller.layoutPaneID, in: shown.content)
        PaneHandlers.focus(shown.left.layoutPaneID, in: shown.content)
        try #require(PaneHandlers.neighbor(of: shown.left.layoutPaneID, direction: .right, in: shown.content) == smaller.layoutPaneID,
                     "the harness: Focus Pane Right does not go to the pane the person was last in: \(shown.content.recentPanes)")

        #expect(Self.run("swapPaneRight", on: shown.left, shown))
        let swapped = Self.three(Self.below, Self.right, Self.left)
        #expect(shown.store.screen(containing: Self.left)?.layout == swapped, "the store does not show the swap with Focus Pane's neighbor")
        // One pending change, and it is that swap (the tree above): what the registry sends is what the screen shows.
        #expect(shown.store.pendingIntents.count == 1, "the swap shown is not one pending change: \(shown.store.pendingIntents)")
        #expect(shown.order == [Self.below, Self.right, Self.left], "the layout does not show the swap with Focus Pane's neighbor: \(shown.order)")
        #expect(shown.frame(shown.left) == before, "the left pane did not take its neighbor's place: \(String(describing: shown.frame(shown.left)))")
        let applies = shown.content.debugApplies

        // What the daemon sends for `swap-pane` with that `target` (`swap_layout_panes`), before the command's answer.
        let echo = ScreenLayoutDelta(activePane: Self.left, layout: swapped)
        shown.store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .layoutChanged(screen: Self.screen, layout: echo, transaction: nil))])
        shown.content.applyLayoutIfChanged()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(shown.content.debugApplies == applies, "the daemon's echo of the shown swap applied the layout \(shown.content.debugApplies - applies) more time(s)")
        #expect(shown.order == [Self.below, Self.right, Self.left], "the daemon's echo swapped the panes back or again: \(shown.order)")
        #expect(shown.store.screen(containing: Self.left)?.layout == swapped)
    }

    // MARK: (c) refusal

    @Test func aRefusedZoomIsTakenBackAndReported() async throws {
        let shown = try await Self.shown()
        defer { shown.close() }

        var ran = false
        let work = shown.services.registry.capturingWork { ran = Self.run("toggleSplitZoom", on: shown.left, shown) }
        #expect(ran)
        try #require(shown.zoomed, "the zoom does not show before the daemon's answer, so there is nothing to take back")
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }

        #expect(failures.count == 1, "the refused zoom is reported once to its caller: \(failures)")
        let back = await Self.eventually { !shown.zoomed }
        #expect(back, "the layout model is still zoomed after the daemon refused the zoom")
        #expect(shown.order == [Self.left, Self.right], "the refused zoom did not bring the panes back: \(shown.order)")
        #expect(shown.store.screen(containing: Self.left)?.zoomedPane == nil, "the store still shows the refused zoom")
        #expect(shown.store.pendingIntents.isEmpty, "the refused zoom is still pending")
    }

    @Test func aRefusedSwapIsTakenBackAndReported() async throws {
        let shown = try await Self.shown()
        defer { shown.close() }

        var ran = false
        let work = shown.services.registry.capturingWork { ran = Self.run("swapPaneRight", on: shown.left, shown) }
        #expect(ran)
        try #require(shown.order == [Self.right, Self.left], "the swap does not show before the daemon's answer, so there is nothing to take back")
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }

        #expect(failures.count == 1, "the refused swap is reported once to its caller: \(failures)")
        let back = await Self.eventually { shown.order == [Self.left, Self.right] }
        #expect(back, "the panes did not go back after the daemon refused the swap: \(shown.order)")
        #expect(shown.store.screen(containing: Self.left)?.layout == Self.split(Self.left, Self.right), "the store still shows the refused swap")
        #expect(shown.store.pendingIntents.isEmpty, "the refused swap is still pending")
    }

    // MARK: (d) the daemon's echo

    /// The daemon's `layout-changed` for the zoom the screen already shows: no layout apply, no second motion.
    @Test func theDaemonsEchoOfAShownZoomAppliesNoLayout() async throws {
        let shown = try await Self.shown()
        defer { shown.close() }
        #expect(Self.run("toggleSplitZoom", on: shown.left, shown))
        try #require(shown.zoomed, "the zoom does not show before the daemon's answer, so its echo is the first change")
        let applies = shown.content.debugApplies
        let frame = shown.frame(shown.left)

        // Same turn as the key: the echo comes before the command's own answer, as the daemon sends it.
        let echo = ScreenLayoutDelta(activePane: Self.left, zoomedPane: Self.left, layout: Self.split(Self.left, Self.right))
        shown.store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .layoutChanged(screen: Self.screen, layout: echo, transaction: nil))])
        shown.content.applyLayoutIfChanged()
        // The content's own observation of the store, on later turns.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(shown.content.debugApplies == applies, "the daemon's echo of the shown zoom applied the layout \(shown.content.debugApplies - applies) more time(s)")
        #expect(shown.zoomed && shown.order == [Self.left])
        #expect(shown.frame(shown.left) == frame)
        #expect(shown.store.screen(containing: Self.left)?.zoomedPane == Self.left, "the zoom the daemon confirmed did not stay")
    }

    /// The daemon's `layout-changed` for the swap the screen already shows: no layout apply.
    @Test func theDaemonsEchoOfAShownSwapAppliesNoLayout() async throws {
        let shown = try await Self.shown()
        defer { shown.close() }
        #expect(Self.run("swapPaneRight", on: shown.left, shown))
        try #require(shown.order == [Self.right, Self.left], "the swap does not show before the daemon's answer, so its echo is the first change")
        let applies = shown.content.debugApplies

        let echo = ScreenLayoutDelta(activePane: Self.left, layout: Self.split(Self.right, Self.left))
        shown.store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .layoutChanged(screen: Self.screen, layout: echo, transaction: nil))])
        shown.content.applyLayoutIfChanged()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(shown.content.debugApplies == applies, "the daemon's echo of the shown swap applied the layout \(shown.content.debugApplies - applies) more time(s)")
        #expect(shown.order == [Self.right, Self.left], "the swap the daemon confirmed did not stay: \(shown.order)")
        #expect(shown.store.screen(containing: Self.left)?.layout == Self.split(Self.right, Self.left))
    }

    /// The daemon also sends `tree-changed` for a swap, and the snapshot the client then reads lists the screen's pane
    /// records in the new tree order. The store's records change order; the layout the window shows is the same tree,
    /// so no layout is applied.
    @Test func theDaemonsSnapshotOfAShownSwapAppliesNoLayout() async throws {
        let shown = try await Self.shown()
        defer { shown.close() }
        #expect(Self.run("swapPaneRight", on: shown.left, shown))
        try #require(shown.order == [Self.right, Self.left], "the swap does not show before the daemon's answer, so its snapshot is the first change")
        let applies = shown.content.debugApplies
        let leftFrame = shown.frame(shown.left), rightFrame = shown.frame(shown.right)

        shown.store.apply(snapshot: Self.tree(Self.split(Self.right, Self.left)))
        shown.content.applyLayoutIfChanged()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(shown.content.debugApplies == applies, "the daemon's snapshot of the shown swap applied the layout \(shown.content.debugApplies - applies) more time(s)")
        #expect(shown.order == [Self.right, Self.left], "the swap the daemon confirmed did not stay: \(shown.order)")
        #expect(shown.frame(shown.left) == leftFrame && shown.frame(shown.right) == rightFrame)
    }
}
