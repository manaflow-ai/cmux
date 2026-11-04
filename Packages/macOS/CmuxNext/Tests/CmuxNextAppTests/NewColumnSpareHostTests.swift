import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// TERMINAL CREATE COST item 4 (lead, STATUS 12604): after #35521 the New Column key turn still added the new pane's host
/// (`PaneHostView`) to the window: AppKit's `_setWindow` walk over the host and its pane, 2 ms of the 9 ms turn on cmux21. As
/// the pane views (#35521), the host is made ahead and parked in the window while the layout is still, so the key's turn
/// moves no new view into the window. Earlier text (item 2): New Terminal Tab from the docked agent chat opens a New Column, and
/// its key turn took 10-11 ms on cmux21, of which 3.5 ms built the new pane's views (PaneContentView, TabStripView and its
/// buttons) and 2 ms added them to the window. As Chrome keeps a spare renderer for its next tab, each shown workspace
/// keeps one pane's strip model and views made ahead while the app is still, out of every window: a pane made in a key's
/// turn (New Column, New Row, Cmd-D) adopts them, so the key's turn builds no pane view and no view leaves a window.
///
/// The test is the layout's clock (`DisplayLinkDriver.isManual`); the daemon is an offline store.
@Suite(.closesItsWindows)
@MainActor struct NewColumnSpareHostTests {
    static let dt = 1.0 / 120

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: CmuxNextDaemon.PaneID(rawValue: 1), tabs: [TabSnapshot(surface: CmuxNextDaemon.SurfaceID(rawValue: 1), title: "~")])
        let column = ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: 11), width: 0.5, layout: .leaf(CmuxNextDaemon.PaneID(rawValue: 1)))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(CmuxNextDaemon.PaneID(rawValue: 1)), columns: [column], panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"new-column-spare-host-test","generation":"g1"}"#
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
    func aNewColumnsKeyTurnPutsNoNewViewInTheWindow() async throws {
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
        root.context.reduceMotionOverride = true // no pane springs: the code works with no animation
        root.driver.isManual = true
        root.driver.detach()
        root.driver.attach(to: root)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        var frames = 0
        while frames < 600, root.advanceFrame(Self.dt) { frames += 1 }
        for _ in 0..<4 {
            await Self.nextCommittedPass()
            services.mainWork.frameDidFire()
        }
        await Self.drainMain()
        try #require(content.panes.count == 1, "fixture: one pane")
        // Every view in the window before the key.
        func inWindow() -> Set<ObjectIdentifier> {
            var seen: Set<ObjectIdentifier> = [], stack = [window.contentView].compactMap { $0 }
            while let view = stack.popLast() { seen.insert(ObjectIdentifier(view)); stack.append(contentsOf: view.subviews) }
            return seen
        }
        let before = inWindow()

        // The key's turn of New Column (`WorkspaceContentController.newColumn` -> `createInKeysTurn`).
        let provisional = ProvisionalPane(columnWidth: 0.5, left: false)
        store.intend(.splitPane(pane: CmuxNextDaemon.PaneID(rawValue: 1), direction: .right, ratio: 0.5, provisional: provisional.opening(in: nil)),
                     transaction: ClientTransactionID.generate())
        content.applyCurrent()

        let made = try #require(content.panes.values.first { $0.pane.handle == provisional.handle }, "the key's turn did not mount the new column's pane")
        let host = try #require(made.view.superview?.superview, "the new pane has no host")
        #expect(made.view.window === window && host.window === window, "the new column is not in the window in the key's turn")
        #expect(before.contains(ObjectIdentifier(host)), "the key's turn put a new pane host in the window (AppKit's window walk)")
        #expect(before.contains(ObjectIdentifier(made.view)), "the key's turn put a new pane view in the window")
        #expect(!host.isHidden && !made.view.isHiddenOrHasHiddenAncestor, "the new column's pane does not show")
    }
}
