import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// BROWSER VIDEO F5 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz films, 2026-11-02): after the close key the docked
/// DevTools stayed on screen and the page kept its docked frame for 3-6 refreshes. The pane changed only on Chromium's
/// DEVTOOLS_CLOSED, which comes after Chromium tore the DevTools browser down (CloseDevTools -> OnBeforeClose), turns
/// later. As in Chrome, which hides the docked DevTools view and gives the page its whole area when the close is asked,
/// the close key's own turn now hides the DevTools area and lays the page out at full size; DEVTOOLS_CLOSED only frees
/// the views. An open asked before that event waits for it (Chromium still has the closing DevTools).
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFDevToolsCloseTests {
    @Test(arguments: [BrowserDevToolsDock.right, .bottom], [BrowserDevToolsCommand.close, .toggle])
    func theCloseKeysTurnGivesThePageItsWholeArea(dock: BrowserDevToolsDock, command: BrowserDevToolsCommand) async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(dock)
        let host = try #require(tab.devToolsController.views?.host)
        ShimLog.calls = []
        tab.performDevTools(command)
        // The close key's own turn: Chromium was asked to close, and has not reported DEVTOOLS_CLOSED yet.
        #expect(ShimLog.calls == ["command \(Rig.browser) close"])
        #expect(!tab.devToolsController.reservesRoom, "the page takes its whole area in the key's turn")
        #expect(tab.devToolsController.frames(in: tab.container.bounds).page == tab.container.bounds)
        #expect(host.isHiddenOrHasHiddenAncestor, "the DevTools area is hidden in the key's turn")
        #expect(!tab.devTools.isOpen, "the tab's DevTools state is closed in the key's turn")
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))
        #expect(tab.devToolsController.views == nil, "DEVTOOLS_CLOSED frees the views")
        #expect(host.superview == nil)
    }

    /// The person opens DevTools again before Chromium finished closing it: the open waits for DEVTOOLS_CLOSED (the
    /// shim would only focus the closing DevTools), then goes once.
    @Test func anOpenDuringTheCloseGoesAfterChromiumClosed() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.right)
        tab.performDevTools(.toggle)
        ShimLog.calls = []
        tab.performDevTools(.toggle)
        await rig.passes(20)
        #expect(!ShimLog.calls.contains { $0.hasSuffix("show") }, "no open while Chromium still closes DevTools")
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))
        await rig.until { ShimLog.calls.contains { $0.hasSuffix("show") } }
        #expect(ShimLog.calls.filter { $0.hasSuffix("show") }.count == 1, "one open after the close")
    }

    /// Close, open, close again before DEVTOOLS_CLOSED: nothing opens after it.
    @Test func aSecondToggleDuringTheCloseTakesThePendingOpenBack() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.bottom)
        tab.performDevTools(.toggle)
        tab.performDevTools(.toggle)
        tab.performDevTools(.toggle)
        ShimLog.calls = []
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))
        await rig.passes(20)
        #expect(ShimLog.calls.isEmpty, "the last toggle closed: nothing opens")
        #expect(!tab.devToolsController.reservesRoom)
        #expect(tab.devToolsController.views == nil)
    }

    /// Review finding at bafa181802e: Chromium opens a new DevTools (the page's Inspect) before the older close's
    /// DEVTOOLS_CLOSED. The new DevTools shows in the views (not hidden), and its own close works.
    @Test func aDevToolsChromiumOpensDuringTheCloseShowsAndCloses() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.right)
        tab.performDevTools(.close)
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        rig.runtime.handle(.devToolsOpened(browser: Rig.browser, devTools: Rig.devTools + 1, docked: true))
        let host = try #require(tab.devToolsController.views?.host)
        #expect(!host.isHiddenOrHasHiddenAncestor, "the new DevTools is shown")
        #expect(tab.devToolsController.reservesRoom)
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))  // the older one
        #expect(tab.devTools.isOpen, "the older DevTools' event leaves the new one open")
        ShimLog.calls = []
        tab.performDevTools(.close)
        #expect(ShimLog.calls == ["command \(Rig.browser) close"], "the new DevTools closes")
        #expect(!tab.devToolsController.reservesRoom)
    }

    /// Review finding at bafa181802e: a panel asked during the close (the closing DevTools would take it and stay
    /// closed) goes after DEVTOOLS_CLOSED.
    @Test func aPanelDuringTheCloseGoesAfterChromiumClosed() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.bottom)
        tab.performDevTools(.close)
        ShimLog.calls = []
        tab.performDevTools(.panel(.network))
        #expect(ShimLog.calls.isEmpty, "no panel while Chromium still closes DevTools")
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))
        #expect(ShimLog.calls == ["panel \(Rig.browser) network"])
    }

    // MARK: Wrong target (#32032 review findings 3 and the base case, lead 10:15Z)

    /// Console and Inspect Element run Chromium's own commands on the pane's active Chromium tab. A console that waited
    /// for the close, run after the person switched to another tab of the pane, opened DevTools on that other page. It
    /// must reach its own page: the console panel of this tab's DevTools (the shim's panel open targets the browser).
    @Test func aConsoleThatWaitedForTheCloseOpensOnItsOwnPageAfterATabSwitch() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.right)
        tab.performDevTools(.close)
        tab.performDevTools(.console)  // waits for DEVTOOLS_CLOSED
        tab.container.isHidden = true  // another tab of the pane shows (PaneContentView parks this one)
        ShimLog.calls = []
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))
        await rig.passes(20)
        #expect(!ShimLog.calls.contains("command \(Rig.browser) console"), "no Chromium console command: it acts on the shown tab")
        #expect(ShimLog.calls == ["panel \(Rig.browser) console"], "this page's DevTools opens on its console")
    }

    /// The same for a console or Inspect asked directly on a parked tab (a script, the CLI): never the shown tab's page.
    @Test(arguments: [(BrowserDevToolsCommand.console, "console"), (.inspectElement, "elements")])
    func consoleOrInspectOnAParkedTabTargetsItsOwnPage(command: BrowserDevToolsCommand, panel: String) throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        tab.performDevTools(.dock(.bottom))
        tab.container.isHidden = true
        ShimLog.calls = []
        tab.performDevTools(command)
        #expect(ShimLog.calls == ["panel \(Rig.browser) \(panel)"])
    }

    /// The older DevTools' DEVTOOLS_CLOSED can arrive after Chromium began a new DevTools (WILL_OPEN) and before its
    /// OPENED: it must not remove the views the new DevTools was just placed over.
    @Test func anOldCloseEventBetweenANewWillOpenAndOpenedKeepsTheNewViews() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.right)
        tab.performDevTools(.close)
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        let host = try #require(tab.devToolsController.views?.host)
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))  // the older one, late
        #expect(tab.devToolsController.views?.host === host, "the new DevTools' host view stays")
        #expect(host.superview === tab.container)
        rig.runtime.handle(.devToolsOpened(browser: Rig.browser, devTools: Rig.devTools + 1, docked: true))
        #expect(tab.devTools.isOpen)
        #expect(tab.devToolsController.reservesRoom)
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools + 1))
        #expect(!tab.devTools.isOpen, "the new DevTools' own close still closes")
        #expect(tab.devToolsController.views == nil)
    }

    /// Re-review nit at 0b8e75eb1a2: close, the toggle again (an open waits), then Chromium opens DevTools itself: that
    /// DevTools is the open the person asked for. When it later closes by its own X, DevTools must not open again.
    @Test func aChromiumOpenDuringTheCloseTakesThePendingOpen() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.bottom)
        tab.performDevTools(.close)
        tab.performDevTools(.toggle)  // waits for DEVTOOLS_CLOSED
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        rig.runtime.handle(.devToolsOpened(browser: Rig.browser, devTools: Rig.devTools + 1, docked: true))
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))  // the older one
        ShimLog.calls = []
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools + 1))  // its own X
        await rig.passes(20)
        #expect(ShimLog.calls.isEmpty, "nothing opens again")
        #expect(!tab.devTools.isOpen)
    }

    // MARK: Follow-ups of #32246 (lead 12:3xZ)

    /// Chromium began DevTools (WILL_OPEN reserved the room) and never reported it opened (no OPENED: the creation
    /// failed). The page kept its docked frame with an empty DevTools area for good: the room is given back after a
    /// bounded wait, and the layout is the one before the open.
    @Test func aDevToolsThatNeverOpensGivesTheRoomBack() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let clock = ManualClock()
        tab.devToolsController.openTimer = DemandTimer(owner: "test", clock: clock)
        tab.performDevTools(.dock(.right))
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        #expect(tab.devToolsController.reservesRoom, "WILL_OPEN reserves the room")
        try await clock.waitForSleeper()
        clock.advance(by: CEFDevToolsController.openedLimit)
        await rig.until { !tab.devToolsController.reservesRoom }
        #expect(!tab.devToolsController.reservesRoom, "no OPENED: the page gets its whole frame back")
        #expect(tab.devToolsController.frames(in: tab.container.bounds).page == tab.container.bounds)
        let host = try #require(tab.devToolsController.views?.host, "the host view Chromium was given stays alive")
        #expect(host.isHiddenOrHasHiddenAncestor, "and hidden")
        #expect(!tab.devTools.isOpen)
        // A late OPENED still opens, over the same host view, shown.
        rig.runtime.handle(.devToolsOpened(browser: Rig.browser, devTools: Rig.devTools, docked: true))
        #expect(tab.devTools.isOpen)
        #expect(tab.devToolsController.views?.host === host)
        #expect(!host.isHiddenOrHasHiddenAncestor)
        #expect(tab.devToolsController.reservesRoom)
    }

    /// A guard, not a red test: the bounded wait never cuts a DevTools that did open (OPENED cancels it).
    @Test func anOpenedDevToolsKeepsItsRoomPastTheWait() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let clock = ManualClock()
        tab.devToolsController.openTimer = DemandTimer(owner: "test", clock: clock)
        tab.performDevTools(.dock(.bottom))
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        try await clock.waitForSleeper()
        rig.runtime.handle(.devToolsOpened(browser: Rig.browser, devTools: Rig.devTools, docked: true))
        clock.advance(by: CEFDevToolsController.openedLimit * 2)
        await rig.passes(20)
        #expect(tab.devTools.isOpen)
        #expect(tab.devToolsController.reservesRoom)
    }

    /// The frontend's device mode was on when the person closed DevTools, and Chromium began a new DevTools before the
    /// older one's DEVTOOLS_CLOSED (its event is retired, #32246): the older session's device frames must not place
    /// the page in the new DevTools' layout; the tab's own emulation applies again.
    @Test func aNewDevToolsDuringTheCloseDropsTheOldDeviceMode() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.openDockedDevTools(.right)
        ShimLog.inspectedBounds = (0, 0, 390, 844)
        defer { ShimLog.inspectedBounds = nil }
        tab.devToolsController.deviceModeChanged(on: true)
        try #require(tab.devToolsController.deviceModeOn)
        tab.performDevTools(.close)
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        #expect(!tab.devToolsController.deviceModeOn, "the older session's device mode ended with it")
        let frames = tab.devToolsController.frames(in: tab.container.bounds)
        #expect(frames.devTools != tab.container.bounds, "the new DevTools has its docked frame, not the device-mode cover")
        rig.runtime.handle(.devToolsClosed(browser: Rig.browser, devTools: Rig.devTools))  // the older one, retired
        #expect(!tab.devToolsController.deviceModeOn)
    }

    /// Review FIX at 2bbae18e7ed: after an unreported open, a stand-in reuses the kept views; it must show them, and
    /// its rollback (Chromium opens nothing) must keep the host view Chromium was given.
    @Test func aStandInAfterAnUnreportedOpenShowsAndKeepsTheHost() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        let clock = ManualClock()
        tab.devToolsController.openTimer = DemandTimer(owner: "test", clock: clock)
        tab.performDevTools(.dock(.right))
        rig.runtime.handle(.devToolsWillOpen(browser: Rig.browser))
        let host = try #require(tab.devToolsController.views?.host)
        try await clock.waitForSleeper()
        clock.advance(by: CEFDevToolsController.openedLimit)
        await rig.until { !tab.devToolsController.reservesRoom }
        ShimLog.calls = []
        tab.performDevTools(.show)  // the stand-in reuses the kept views
        #expect(tab.devToolsController.standIn)
        #expect(!host.isHiddenOrHasHiddenAncestor, "the stand-in shows the pane's ground")
        await rig.until { ShimLog.calls.contains { $0.hasPrefix("command") } }
        await Task.yield()
        #expect(!tab.devToolsController.reservesRoom, "Chromium opened nothing: the stand-in rolled back")
        #expect(tab.devToolsController.views?.host === host, "the host Chromium was given stays alive")
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 23
        static let devTools: Int32 = 24
        let runtime: CEFRuntime
        let root: URL
        /// The pane's window: DevTools docks only in a tab shown in a window (`CEFDevToolsController.willOpen`).
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)

        init() throws {
            ShimLog.calls = []
            root = FileManager.default.temporaryDirectory.appending(path: "cef-devtools-close-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try ShimLog.library(), storage: CEFProfileStorage(root: root))
        }

        /// A shown tab with DevTools open and docked at `dock` (Chromium's events as for a real open).
        func openDockedDevTools(_ dock: BrowserDevToolsDock) throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            tab.container.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.addSubview(tab.container)
            tab.performDevTools(.dock(dock))
            runtime.handle(.devToolsWillOpen(browser: Self.browser))
            runtime.handle(.devToolsOpened(browser: Self.browser, devTools: Self.devTools, docked: true))
            try #require(tab.devTools.isOpen)
            try #require(tab.devToolsController.reservesRoom)
            ShimLog.calls = []
            return tab
        }

        /// A shown tab in the pane's window, DevTools closed.
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
            // view teardown never reads it after it ended.
            Self.kept.append(self)
        }

        /// Rigs kept alive (see `close`).
        static var kept: [Rig] = []
    }
}

/// The DevTools commands and panels the shim got, in order (the shim is called on the main thread).
private nonisolated enum ShimLog {
    nonisolated(unsafe) static var calls: [String] = []
    /// What `cmux_shim_devtools_inspected_bounds` answers (nil: no device mode area).
    nonisolated(unsafe) static var inspectedBounds: (Int32, Int32, Int32, Int32)?

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { browser, command, _, _ in
            let name = [CEFShimLibrary.DevToolsCommand.show: "show", CEFShimLibrary.DevToolsCommand.close: "close",
                        CEFShimLibrary.DevToolsCommand.console: "console", CEFShimLibrary.DevToolsCommand.inspect: "inspect"][command]
            ShimLog.calls.append("command \(browser) \(name ?? String(command))")
            return 1
        }
        let panel: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { browser, id in
            ShimLog.calls.append("panel \(browser) \(id.map { String(cString: $0) } ?? "")")
            return 1
        }
        let bounds: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                    UnsafeMutablePointer<Int32>?) -> Int32 = { _, x, y, width, height in
            guard let area = ShimLog.inspectedBounds else { return 0 }
            x?.pointee = area.0
            y?.pointee = area.1
            width?.pointee = area.2
            height?.pointee = area.3
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_show_panel": unsafeBitCast(panel, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_inspected_bounds": unsafeBitCast(bounds, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
