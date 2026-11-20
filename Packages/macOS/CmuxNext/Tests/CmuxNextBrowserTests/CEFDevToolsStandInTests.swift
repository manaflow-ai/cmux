import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextTestSupport
import Foundation
import Testing

/// BROWSER VIDEO F3 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz films on feat 0d19fe6, 2026-11-02): after a real
/// Cmd-Opt-I the first changed frame came 5-9 refreshes (40-75 ms) after the app got the key, in every open. The page
/// area and the docked DevTools area changed only when Chromium had created DevTools inside the key's turn
/// (ShowDevTools -> DEVTOOLS_WILL_OPEN), so the turn, and its frame, waited for that. As every create in cmux
/// (PATTERNS.md P4, instant create), the key's turn now shows a stand-in: the page takes its docked frame and the
/// DevTools area the pane's themed ground, that frame is committed, and Chromium creates DevTools in the next turn.
/// When Chromium opens nothing, the stand-in rolls back.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFDevToolsStandInTests {
    @Test(arguments: [BrowserDevToolsCommand.show, .toggle, .console, .inspectElement])
    func theKeysTurnShowsTheDockedLayoutBeforeChromiumCreatesDevTools(command: BrowserDevToolsCommand) async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.right))
        tab.performDevTools(command)
        // The key's own turn: the room is reserved and the DevTools area is in the pane; Chromium was not asked yet.
        #expect(tab.devToolsController.reservesRoom, "the page takes its docked frame in the key's turn")
        #expect(tab.devToolsController.views?.host.superview === tab.container, "the DevTools area shows the pane's ground")
        #expect(!ShimLog.calls.contains { $0.hasPrefix("command") }, "Chromium's DevTools creation waits for the next turn")
        let frames = tab.devToolsController.frames(in: tab.container.bounds)
        #expect(frames.devTools.width > 0 && frames.page.width < tab.container.bounds.width)
        await rig.until { ShimLog.calls.contains { $0.hasPrefix("command") } }
        #expect(ShimLog.calls.filter { $0.hasPrefix("command") }.count == 1, "one open")
    }

    /// NEWTAB DEVTOOLS FRAMES (#32911, pacing triage on feat 585171513e37, 120 Hz films): the stand-in's ask ran as a
    /// main-actor `Task`, which runs from the main queue in the same run-loop pass as the key, before that pass's Core
    /// Animation commit. So CefBrowserHost::ShowDevTools (about 18 ms, Chromium creates DevTools there) was inside the
    /// key's commit (commit_ms 43 ms p50, 9 missed vsyncs). Chrome commits the frame the input changed first: Chromium is
    /// asked only after the pass that shows the stand-in committed its frame.
    @Test func chromiumIsAskedOnlyAfterTheKeysFrameCommitted() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        // Which stage of the main run loop's pass the command runs in. Core Animation commits at before-waiting, order
        // 2,000,000: this observer runs right after that commit and marks what follows as after it. Every other stage
        // of a pass (the input's sources, the main queue's jobs, timers) is the turn before the commit.
        ShimLog.stage = .turn
        let turn = MainRunLoopObserver(activities: [.beforeTimers, .beforeSources, .afterWaiting], order: 0) { _ in ShimLog.stage = .turn }
        let committed = MainRunLoopObserver(activities: .beforeWaiting, order: 2_000_001) { _ in ShimLog.stage = .afterCommit }
        defer { turn.invalidate(); committed.invalidate() }
        // The key arrives as a person's key does: in a run-loop callout, not in a main-queue job.
        MainRunLoopBlock.perform { tab.performDevTools(.show) }
        await rig.until { ShimLog.calls.contains { $0.hasPrefix("command") } }
        #expect(ShimLog.calls.filter { $0.hasPrefix("command") } == ["command \(Rig.browser) show"], "one open")
        #expect(ShimLog.commandStages == [.afterCommit], "Chromium creates DevTools only after the key's frame committed")
    }

    /// The fake Chromium opens nothing (no DEVTOOLS_WILL_OPEN): the stand-in rolls back after the command.
    @Test func whenChromiumOpensNothingTheStandInRollsBack() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        tab.performDevTools(.show)
        await rig.until { ShimLog.calls.contains { $0.hasPrefix("command") } }
        await Task.yield()
        #expect(!tab.devToolsController.reservesRoom, "the page gets its whole frame back")
        #expect(tab.devToolsController.views == nil)
    }

    /// The person closes DevTools (the toggle again) before Chromium was asked: nothing opens, the room comes back.
    @Test func aToggleDuringTheStandInCancelsIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        tab.performDevTools(.toggle)
        tab.performDevTools(.toggle)
        #expect(!tab.devToolsController.reservesRoom)
        await rig.passes(20)
        #expect(!ShimLog.calls.contains { $0.hasPrefix("command") }, "Chromium was never asked to open DevTools")
    }

    /// Review FIX at 978de5b4b47: console and inspect act on the pane's active Chromium tab, so a tab switch between
    /// the key's turn and the next must not send them (they would open DevTools on the other page): the stand-in rolls
    /// back instead.
    @Test func aTabSwitchBeforeTheNextTurnSendsNothingAndRollsBack() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.right))
        tab.performDevTools(.console)
        #expect(tab.devToolsController.standIn)
        tab.container.isHidden = true  // another tab of the pane shows (PaneContentView parks this one)
        await rig.passes(20)
        #expect(!ShimLog.calls.contains { $0.hasPrefix("command") }, "no console for a page that is not shown")
        #expect(!tab.devToolsController.reservesRoom, "the stand-in rolled back")
    }

    /// Re-review FIX at 55ed84f60a8: a scripted open aimed at a parked (hidden) tab must still open, at once, as
    /// before the stand-in existed; the stand-in is only for the shown tab.
    @Test func anOpenOnAParkedTabGoesAtOnce() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        tab.container.isHidden = true  // parked: another tab of the pane shows
        tab.performDevTools(.show)
        #expect(ShimLog.calls.filter { $0.hasPrefix("command") } == ["command \(Rig.browser) show"])
        #expect(!tab.devToolsController.standIn)
    }

    /// A stale ask never runs: console's stand-in, cancelled by the toggle, then a new stand-in by the toggle sends
    /// exactly one command, the new one.
    @Test func onlyTheNewestStandInsCommandIsSent() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        tab.performDevTools(.console)
        tab.performDevTools(.toggle)  // cancels the console stand-in
        tab.performDevTools(.toggle)  // a new stand-in for show
        await rig.until { ShimLog.calls.contains { $0.hasPrefix("command") } }
        await rig.passes(20)
        #expect(ShimLog.calls.filter { $0.hasPrefix("command") } == ["command \(Rig.browser) show"])
    }

    /// A Chromium that creates DevTools (DEVTOOLS_WILL_OPEN inside the command) keeps the stand-in's views.
    @Test func devToolsOpensIntoTheStandInsArea() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.right))
        ShimLog.onShow = { rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser)) }
        tab.performDevTools(.show)
        let standIn = try #require(tab.devToolsController.views?.host)
        await rig.until { ShimLog.calls.contains { $0.hasPrefix("command") } }
        await Task.yield()
        #expect(tab.devToolsController.views?.host === standIn, "Chromium's DevTools goes over the stand-in's view")
        #expect(tab.devToolsController.reservesRoom)
        ShimLog.onShow = nil
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 17
        let runtime: CEFRuntime
        let root: URL
        /// The pane's window: DevTools docks only in a tab shown in a window (`CEFDevToolsController.willOpen`).
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)

        init() throws {
            ShimLog.calls = []
            ShimLog.commandStages = []
            root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-standin-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try ShimLog.library(), storage: CEFProfileStorage(root: root))
        }

        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            tab.container.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.addSubview(tab.container)
            ShimLog.calls = []
            return tab
        }

        /// Runs main-actor jobs and main run-loop passes (with their observers: the frame commit) until `condition`.
        func until(_ condition: () -> Bool) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !condition(), clock.now < deadline { await pass() }
        }

        /// `count` main run-loop passes, each after the main-actor jobs queued so far.
        func passes(_ count: Int) async {
            for _ in 0..<count { await pass() }
        }

        private func pass() async {
            await Task.yield()
            Self.runLoopPass()
        }

        /// One main run-loop pass, with its before-waiting observers (the frame commit's stage). Synchronous: the
        /// run loop cannot be run from an async context directly.
        private static func runLoopPass() {
            _ = CFRunLoopRunInMode(.defaultMode, 0.001, false)
        }

        func close() {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            // Closed, not only emptied: a window never closed is left open (`.closesItsWindows`).
            window.closeAfterTest()
            try? FileManager.default.removeItem(at: root)
            // The runtime is `unowned` in its tabs and hosts: kept to the end of the test process so a late task or
            // view teardown never reads it after it ended (the red run crashed there).
            Self.kept.append(self)
        }

        /// Rigs kept alive (see `close`).
        static var kept: [Rig] = []
    }
}

/// The DevTools calls the shim got, in order (the shim is called on the main thread).
private nonisolated enum ShimLog {
    nonisolated(unsafe) static var calls: [String] = []
    /// Runs inside the show command (a Chromium that creates DevTools sends DEVTOOLS_WILL_OPEN there).
    nonisolated(unsafe) static var onShow: (@MainActor () -> Void)?
    /// The run-loop stage the main thread is in (``CEFDevToolsStandInTests/chromiumIsAskedOnlyAfterTheKeysFrameCommitted()``).
    enum Stage: Equatable { case turn, afterCommit }
    nonisolated(unsafe) static var stage = Stage.turn
    /// The stage each command was sent in.
    nonisolated(unsafe) static var commandStages: [Stage] = []

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { browser, command, _, _ in
            let name = [CEFShimLibrary.DevToolsCommand.show: "show", CEFShimLibrary.DevToolsCommand.close: "close",
                        CEFShimLibrary.DevToolsCommand.console: "console", CEFShimLibrary.DevToolsCommand.inspect: "inspect"][command]
            ShimLog.calls.append("command \(browser) \(name ?? String(command))")
            ShimLog.commandStages.append(ShimLog.stage)
            if let onShow = ShimLog.onShow { MainActor.assumeIsolated { onShow() } }
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
