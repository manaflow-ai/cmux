import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE VIDEOS F1 (STATUS 6164, 6209; feat e34fecc1312): one refresh is lost at the start of every close. #31811
/// keeps the closed pane's HOST until the motion lands, but its CONTENT still went in the close's first frames: the
/// close's reply and the gone-tab watch (the tree no longer lists the tab) release the tab at once
/// (`TabContentCache.release`), which takes the terminal view out of the closing pane (`surfaceWasDisplaced`) and
/// closes its surface; the views then deallocate in the next autorelease pop and Core Animation commit. In the
/// suite's xctrace profiles on the tip that teardown is about a quarter of the main thread's time in the close's
/// first two intervals, which miss refreshes at 120 Hz. Work no frame shows must not run in the motion: the
/// closed pane's content stays (hidden, with its host) until the pane is torn down at the landing, and goes then.
///
/// The test is the layout's clock (`DisplayLinkDriver.isManual`, 120 Hz steps); the daemon is an offline store.
@Suite(.closesItsWindows)
@MainActor struct ClosedPaneContentStaysUntilLandingTests {
    static let dt = 1.0 / 120

    private static func tree(_ panes: [UInt64]) -> DaemonTree {
        let snapshots = panes.map { PaneSnapshot(id: CmuxNextDaemon.PaneID(rawValue: $0), tabs: [TabSnapshot(surface: CmuxNextDaemon.SurfaceID(rawValue: $0), title: "~")]) }
        let columns = panes.map { ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: 10 + $0), width: 1.0 / 3, layout: .leaf(CmuxNextDaemon.PaneID(rawValue: $0))) }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(CmuxNextDaemon.PaneID(rawValue: panes[0])), columns: columns, panes: snapshots)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"closed-pane-content-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Lets the main actor run what is queued (observation steps, the gone-tab watch): a fixed number of yields, no
    /// wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Waits until two main run-loop passes have committed, so after-commit work the landing scheduled has run: the
    /// signal `AfterFrameCommit` uses, a one-shot before-waiting observer after every other observer of the pass.
    private static func nextCommittedPasses() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                  false, CFIndex.max) { _, _ in
                    done.resume()
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aClosingPanesContentStaysUntilTheMotionLands() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let cache = services.cache
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1, 2, 3]))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        // The controller holds its window state unowned: the test keeps it alive, as its window does.
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
        // Pins the pane springs on without touching the shared settings; from here the test is the clock.
        root.context.reduceMotionOverride = false
        root.driver.isManual = true
        root.driver.detach()
        root.driver.attach(to: root)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        for _ in 0..<600 where root.advanceFrame(Self.dt) {}
        // Every pane shows its terminal (the display frames the presentation scheduler would run them in).
        for pane in content.panes.values { pane.showSelected() }
        await Self.drainMain()

        let closing = try #require(content.panes.values.first { $0.pane.handle == CmuxNextDaemon.PaneID(rawValue: 2) }, "fixture: pane 2 is mounted")
        let closedTab = try #require(store.tab(surface: CmuxNextDaemon.SurfaceID(rawValue: 2))?.id)
        try #require(closing.currentTabKey == closedTab, "fixture: pane 2 shows its terminal")
        try #require(cache.existingTerminal(closedTab) != nil, "fixture: pane 2's terminal exists")
        let kept = try #require(store.tab(surface: CmuxNextDaemon.SurfaceID(rawValue: 1))?.id)

        // The close's turn (Cmd-W on pane 2's last tab): the pane leaves its window, its neighbours spring into its place.
        let close = try #require(closing.showPaneClose(), "fixture: the layout shows the close")
        let screen = try #require(root.screenViews.values.first { !$0.isHidden })
        try #require(screen.hasMotion, "fixture: the close springs")
        // The daemon's tree drops the pane (its gone-tab watch wakes), the close's reply settles it and releases its tab.
        store.apply(snapshot: Self.tree([1, 3]))
        await Self.drainMain()
        closing.finishPaneClose(close, failed: false)
        cache.release(closedTab)

        var releasedInFrame: Int?
        var frames = 0
        if cache.existingTerminal(closedTab) == nil || closing.currentTabKey != closedTab { releasedInFrame = 0 }
        while frames < 600 {
            let moving = root.advanceFrame(Self.dt)
            frames += 1
            await Self.drainMain()
            if !moving { break }
            if releasedInFrame == nil, cache.existingTerminal(closedTab) == nil || closing.currentTabKey != closedTab {
                releasedInFrame = frames
            }
        }
        await Self.nextCommittedPasses()
        #expect(frames > 10, "the close springs over several frames (\(frames))")
        #expect(releasedInFrame == nil,
                "the closed pane's terminal was torn down in motion frame \(releasedInFrame ?? -1) of \(frames): work no frame shows ran in the motion")
        #expect(cache.existingTerminal(closedTab) == nil, "the closed pane's terminal stayed after the motion landed")
        #expect(cache.existingTerminal(kept) != nil, "a pane that stays lost its terminal")
    }
}
