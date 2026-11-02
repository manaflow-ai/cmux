import AppKit
@testable import CmuxNextBrowser
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
        for _ in 0..<20 { await Task.yield() }
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
        for _ in 0..<20 { await Task.yield() }
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

        func until(_ condition: () -> Bool) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !condition(), clock.now < deadline { await Task.yield() }
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
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_show_panel": unsafeBitCast(panel, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
