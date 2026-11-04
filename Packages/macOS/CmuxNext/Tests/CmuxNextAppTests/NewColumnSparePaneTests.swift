import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// TERMINAL CREATE COST item 2 (STATUS 11351, 11836): New Terminal Tab from the docked agent chat opens a New Column, and
/// its key turn took 10-11 ms on cmux21, of which 3.5 ms built the new pane's views (PaneContentView, TabStripView and its
/// buttons) and 2 ms added them to the window (AppKit's `_setWindow` walk over the new subtree). As Chrome keeps a spare
/// renderer for its next tab, each window keeps one spare pane view, built after a frame committed and parked in the
/// window: a pane made in a key's turn (New Column, New Row, Cmd-D) adopts it, so the key's turn builds no pane view.
///
/// The test is the layout's clock (`DisplayLinkDriver.isManual`); the daemon is an offline store.
@Suite(.closesItsWindows)
@MainActor struct NewColumnSparePaneTests {
    static let dt = 1.0 / 120

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: CmuxNextDaemon.PaneID(rawValue: 1), tabs: [TabSnapshot(surface: CmuxNextDaemon.SurfaceID(rawValue: 1), title: "~")])
        let column = ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: 11), width: 0.5, layout: .leaf(CmuxNextDaemon.PaneID(rawValue: 1)))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(CmuxNextDaemon.PaneID(rawValue: 1)), columns: [column], panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"new-column-spare-pane-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Waits until the main run loop's pass has committed (a one-shot before-waiting observer after every other one).
    private static func nextCommittedPass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                done.resume()
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    /// Every view in `root`'s subtree.
    private static func subtree(_ root: NSView) -> Set<ObjectIdentifier> {
        var seen: Set<ObjectIdentifier> = [], stack = [root]
        while let view = stack.popLast() {
            seen.insert(ObjectIdentifier(view))
            stack.append(contentsOf: view.subviews)
        }
        return seen
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewColumnsKeyTurnBuildsNoPaneView() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
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
        window.orderFrontRegardless()
        let root = content.layoutView
        root.driver.isManual = true
        root.driver.detach()
        root.driver.attach(to: root)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        var frames = 0
        while frames < 600, root.advanceFrame(Self.dt) { frames += 1 }
        // Frames committed and the main actor went idle: what the window prepares ahead of a key is ready now. The app's
        // scheduler runs its background work on display frames; the test is its frame (the first task of a frame runs).
        for _ in 0..<4 {
            await Self.nextCommittedPass()
            services.mainWork.frameDidFire()
        }
        await Self.drainMain()
        let before = Self.subtree(window.contentView ?? content.contentView)
        try #require(content.panes.count == 1, "fixture: one pane")

        // The key's turn of New Column (`WorkspaceContentController.newColumn` -> `createInKeysTurn`): the stand-in pane in
        // the store, then laid out and mounted before the key's frame.
        let provisional = ProvisionalPane(columnWidth: 0.5, left: false)
        store.intend(.splitPane(pane: CmuxNextDaemon.PaneID(rawValue: 1), direction: .right, ratio: 0.5, provisional: provisional.opening(in: nil)),
                     transaction: ClientTransactionID.generate())
        content.applyCurrent()

        let made = try #require(content.panes.values.first { $0.pane.handle == provisional.handle }, "the key's turn did not mount the new column's pane")
        #expect(made.view.window === window, "the new column's pane view is not in the window in the key's turn")
        #expect(before.contains(ObjectIdentifier(made.view)), "the key's turn built the new column's pane view (its PaneContentView is new)")
        #expect(before.contains(ObjectIdentifier(made.view.stripView)), "the key's turn built the new column's tab strip")
        #expect(made.stripModel.selectedID?.rawValue == provisional.tabID, "the new column's strip does not select its stand-in tab")
    }
}
