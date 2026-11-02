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

    /// The layout's after-commit work, collected: the test runs it where a committed frame would (`LayoutViewContext.afterCommit`).
    @MainActor final class Committed {
        var work: [@MainActor () -> Void] = []
        func run() { let pending = work; work = []; for item in pending { item() } }
    }

    /// A window of three terminal panes in columns on an offline store, the layout's clock manual (120 Hz), every pane
    /// showing its terminal, at rest.
    @MainActor final class Fixture {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let state: WindowState
        let window: NSWindow
        let content: WorkspaceContentController
        let committed = Committed()
        var root: LayoutRootView { content.layoutView }
        var store: DaemonStore { services.daemon.store }
        var cache: TabContentCache { services.cache }

        init() async throws {
            _ = NSApplication.shared
            let store = services.daemon.store
            store.connectionState = .connected(try ClosedPaneContentStaysUntilLandingTests.connected())
            store.apply(snapshot: ClosedPaneContentStaysUntilLandingTests.tree([1, 2, 3]))
            let workspace = try #require(store.workspaces.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            // The controller holds its window state unowned: the fixture keeps it alive, as its window does.
            state = WindowState(record: record)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
            window.contentView = content.contentView
            window.orderFrontRegardless()
            // Pins the pane springs on without touching the shared settings; from here the test is the clock.
            root.context.reduceMotionOverride = false
            root.context.afterCommit = { [committed] in committed.work.append($0) }
            root.driver.isManual = true
            root.driver.detach()
            root.driver.attach(to: root)
            content.applyCurrent()
            content.contentView.layoutSubtreeIfNeeded()
            settle()
            // Every pane shows its terminal (the display frames the presentation scheduler would run them in).
            for pane in content.panes.values { pane.showSelected() }
            await ClosedPaneContentStaysUntilLandingTests.drainMain()
        }

        /// Steps frames until the layout rests (at most 5 s) and returns how many ran.
        @discardableResult func settle() -> Int {
            var frames = 0
            while frames < 600, root.advanceFrame(ClosedPaneContentStaysUntilLandingTests.dt) { frames += 1 }
            return frames
        }

        func close() { withExtendedLifetime((services, state)) { content.teardown(); window.close() } }

        func pane(_ id: UInt64) throws -> PaneController {
            try #require(content.panes.values.first { $0.pane.handle == CmuxNextDaemon.PaneID(rawValue: id) }, "fixture: pane \(id) is mounted")
        }

        func tab(_ id: UInt64) throws -> String {
            try #require(store.tab(surface: CmuxNextDaemon.SurfaceID(rawValue: id))?.id)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aClosingPanesContentStaysUntilTheMotionLands() async throws {
        let app = try await Fixture()
        defer { app.close() }
        let closing = try app.pane(2), closedTab = try app.tab(2), kept = try app.tab(1)
        try #require(closing.currentTabKey == closedTab, "fixture: pane 2 shows its terminal")
        try #require(app.cache.existingTerminal(closedTab) != nil, "fixture: pane 2's terminal exists")

        // The close's turn, as Cmd-W on pane 2's last tab runs it (`PaneController.prepareClose`): the tab leaves the
        // strip (the pane withdraws its terminal), the pane leaves its window and its neighbours spring into its place.
        let prepared = try #require(closing.prepareClose(closing.stripModel.orderedTabs.map(\.id)), "fixture: the close has a daemon tab")
        let screen = try #require(app.root.screenViews.values.first { !$0.isHidden })
        try #require(screen.hasMotion, "fixture: the close springs")
        // The next frame's content presentation (the scheduler runs it on the display link): the pane withdraws the tab
        // the strip no longer lists, so the cache has no presenter for it any more.
        closing.showSelected()
        try #require(app.cache.presenter(of: closedTab) == nil, "fixture: the closing pane withdrew its tab")
        // A close releases its tab more than once before it lands: the gone-tab watch on the tree that drops the pane and
        // again on each later tree revision, then the reply's finish. Every one of them waits for the landing (review of
        // #32197: the second release found no pane and ran in the motion).
        app.store.apply(snapshot: ClosedPaneContentStaysUntilLandingTests.tree([1, 3]))
        await ClosedPaneContentStaysUntilLandingTests.drainMain()
        // The test applies the tree as a whole snapshot, which shows the closing pane's tab again for a moment (the
        // daemon's own tab-closed event does not). The app's frame withdraws it again; so does the test, so every
        // release below finds no presenter, as in the app (review of #32197: only the withdrawing pane holds them then).
        if app.cache.presenter(of: closedTab) != nil { app.cache.withdraw(closedTab, by: closing) }
        try #require(app.cache.presenter(of: closedTab) == nil, "fixture: no pane presents the closing tab")
        func state() -> String { "presenter \(app.cache.presenter(of: closedTab) != nil), withdrawn \(app.cache.withdrawnBy[closedTab]?.value != nil)" }
        app.cache.release(closedTab) // the gone-tab watch on the tree that dropped the pane
        #expect(app.cache.existingTerminal(closedTab) != nil, "the first release ran at once (\(state()))")
        app.cache.release(closedTab) // the watch again, on the next tree revision
        #expect(app.cache.existingTerminal(closedTab) != nil, "the second release ran at once (\(state()))")
        await prepared.finish(false, false) // the reply's release
        #expect(app.cache.existingTerminal(closedTab) != nil, "the reply's release ran at once (\(state()))")

        var releasedInFrame: Int?
        var frames = 0
        if app.cache.existingTerminal(closedTab) == nil { releasedInFrame = 0 }
        while frames < 600 {
            let moving = app.root.advanceFrame(Self.dt)
            frames += 1
            await Self.drainMain()
            if !moving { break }
            app.committed.run() // a motion frame's commit: nothing it ran may take the closed terminal
            if releasedInFrame == nil, app.cache.existingTerminal(closedTab) == nil { releasedInFrame = frames }
        }
        #expect(frames > 10, "the close springs over several frames (\(frames))")
        #expect(releasedInFrame == nil,
                "the closed pane's terminal was torn down in motion frame \(releasedInFrame ?? -1) of \(frames): work no frame shows ran in the motion")
        #expect(app.cache.existingTerminal(closedTab) != nil, "the landing frame itself tore the terminal down, before its commit")
        app.committed.run() // the landing frame committed
        #expect(app.cache.existingTerminal(closedTab) == nil, "the closed pane's terminal stayed after the landing's commit")
        #expect(app.cache.existingTerminal(kept) != nil, "a pane that stays lost its terminal")
    }

    /// A close that does not happen (refused, or a reply that missed its deadline and the next tree still lists the
    /// pane) brings the pane back. A release held for it runs before it shows again, as on a close with no motion, so
    /// no late release takes the terminal the pane shows after it came back (review of #32197, should-fix 2).
    @Test(.timeLimit(.minutes(1)))
    func aPaneThatComesBackKeepsTheTerminalItShows() async throws {
        let app = try await Fixture()
        defer { app.close() }
        let closing = try app.pane(2), tab = try app.tab(2)
        let prepared = try #require(closing.prepareClose(closing.stripModel.orderedTabs.map(\.id)), "fixture: the close has a daemon tab")
        try #require(app.root.screenViews.values.contains { !$0.isHidden && $0.hasMotion }, "fixture: the close springs")
        // A release while it closes (the gone-tab watch or the reply): held for the landing.
        app.cache.release(tab)
        try #require(app.cache.existingTerminal(tab) != nil, "fixture: the release is held while the pane closes")

        // The daemon refused: the pane comes back, and shows its tab again.
        await prepared.finish(true, false)
        await Self.drainMain()
        closing.showSelected()
        await Self.drainMain()
        let shown = try #require(app.cache.existingTerminal(tab), "fixture: the pane that came back shows a terminal")
        for _ in 0..<3 { app.root.advanceFrame(Self.dt); app.committed.run() }
        app.settle()
        app.committed.run()
        await Self.drainMain()

        #expect(closing.currentTabKey == tab, "the pane that came back does not show its tab (\(closing.currentTabKey ?? "nil"))")
        #expect(app.cache.existingTerminal(tab) === shown,
                "a held release ran after the pane came back: it took the terminal the pane showed (the pane blanked and attached again)")
    }
}
