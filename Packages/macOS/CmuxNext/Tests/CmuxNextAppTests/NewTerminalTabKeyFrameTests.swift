import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// TERMINAL CREATE COST (STATUS 11073, 11080): New Terminal Tab (Ctrl-`, `newSurface`) reached its committed frame
/// in about 27 ms p50 and 30 ms p95 on the fleet (cmux19, Release), against the 10 ms action budget. The key's
/// turn put the stand-in tab in the store and selected it (instant create), and then also made the stand-in's
/// Ghostty surface, its host view and its terminal session, in that same turn. As Chrome shows a new tab's strip
/// item before its renderer attaches, the key's frame now shows the stand-in tab selected on its themed pane, and
/// its terminal is made right after that frame committed (`AfterFrameCommit`), with no task, timer or wait.
@Suite(.closesItsWindows)
@MainActor struct NewTerminalTabKeyFrameTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"new-terminal-key-frame-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Waits until the main run loop's pass has committed, so work after a frame's commit has run (the signal
    /// `AfterFrameCommit` uses: a one-shot before-waiting observer after every other observer of the pass).
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

    @Test func theKeysTurnSelectsTheStandInAndMakesItsTerminalRightAfterTheKeysFrame() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let shell = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        window.contentView = pane.view
        window.orderFrontRegardless()
        state.selection.select(shell.id, in: pane.paneKey)
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()
        for _ in 0..<12 where services.cache.existingTerminal(shell.id) == nil { await Self.nextCommittedPass() }
        try #require(services.cache.existingTerminal(shell.id) != nil, "the shown terminal has no view: the test no longer reaches the case")

        // The key's turn, as `PaneController.newTerminalTabNow` runs it: the stand-in in the store, then selected.
        let standIn = ProvisionalTab()
        defer { services.cache.release(standIn.id) }
        store.intend(.createTab(pane: model.handle, provisional: standIn.terminal(TerminalID.generate(), cwd: nil)),
                     transaction: ClientTransactionID.generate())
        pane.selectWhenReported(surface: standIn.surface)

        try #require(pane.stripModel.selectedID?.rawValue == standIn.id, "the key's turn did not select the stand-in")
        #expect(pane.currentTabKey == standIn.id, "the pane still shows the terminal it showed before the key")
        #expect(services.cache.existingTerminal(standIn.id) == nil,
                "the key's turn made the stand-in's Ghostty surface, host view and session (15-20 ms of the 10 ms budget)")
        #expect(pane.view.content == nil, "the key's frame shows another view in the pane than its themed pane")

        // The key's frame commits; the terminal is made right after it (or at the next display frame when a surface was
        // already made in this one: one per frame), and the pane shows it.
        for _ in 0..<12 where services.cache.existingTerminal(standIn.id) == nil || pane.view.content == nil { await Self.nextCommittedPass() }
        let entry = try #require(services.cache.existingTerminal(standIn.id), "no terminal for the stand-in after its key's frame")
        #expect(pane.view.content === entry.session.view, "the pane does not show the stand-in's terminal after its key's frame")
        #expect(pane.currentTabKey == standIn.id)
    }
}
