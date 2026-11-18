import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// 2026-11-17, Settings opens late: Cmd-, from Home's dock makes a new column in the key's turn (a stand-in pane, like New
/// Column), and the key still built the pane's toolbar buttons (PaneToolbarView: the pinned buttons, Exit Zoom and "…"),
/// 15 of 102 key samples in 12 Settings reopens on cmux-lawrence-2 (PaneToolbarView.init under makeContentView). The spare
/// made ahead while the app is still holds them too: the key's turn adopts them as it adopts the pane view.
@Suite(.closesItsWindows)
@MainActor struct NewColumnSpareToolbarTests {
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

    @Test(.timeLimit(.minutes(1)))
    func aNewColumnsKeyTurnBuildsNoToolbarButtons() async throws {
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
        // No pane springs (pinned without touching the shared settings): the code works with no animation; a layout
        // motion is driven explicitly below.
        root.context.reduceMotionOverride = true
        root.driver.isManual = true
        root.driver.detach()
        root.driver.attach(to: root)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        func land() { var frames = 0; while frames < 600, root.advanceFrame(Self.dt) { frames += 1 } }
        /// Committed passes, each followed by the app scheduler's frame (its background work runs on display frames).
        func idle() async {
            for _ in 0..<4 {
                await Self.nextCommittedPass()
                services.mainWork.frameDidFire()
            }
        }
        land()
        await idle()
        await Self.drainMain()
        try #require(content.panes.count == 1, "fixture: one pane")
        let ready = try #require(content.paneSpare.ready, "no pane views were made ahead while the app was still")
        // Parked in the window inside the host made with them (item 4), hidden: the key's turn moves no view out of or into it.
        try #require(ready.view.window === window && ready.view.isHiddenOrHasHiddenAncestor, "the views made ahead are not parked hidden in the window")

        // The key's turn of New Column (`WorkspaceContentController.newColumn` -> `createInKeysTurn`): the stand-in pane in
        // the store, then laid out and mounted before the key's frame.
        let provisional = ProvisionalPane(columnWidth: 0.5, left: false)
        store.intend(.splitPane(pane: CmuxNextDaemon.PaneID(rawValue: 1), direction: .right, ratio: 0.5, provisional: provisional.opening(in: nil)),
                     transaction: ClientTransactionID.generate())
        content.applyCurrent()

        let made = try #require(content.panes.values.first { $0.pane.handle == provisional.handle }, "the key's turn did not mount the new column's pane")
        #expect(made.view.window === window, "the new column's pane view is not in the window in the key's turn")
        #expect(made.view.toolbar?.view === ready.toolbarView, "the key's turn built the new column's toolbar buttons (its PaneToolbarView is new)")

    }
}
