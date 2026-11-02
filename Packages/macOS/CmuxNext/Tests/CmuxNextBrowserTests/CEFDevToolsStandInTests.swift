import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// BROWSER VIDEO F3 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz films on feat 0d19fe6, 2026-11-02): after a real
/// Cmd-Opt-I the first changed frame came 5-9 refreshes (40-75 ms) after the app got the key, in every open. The page
/// area and the docked DevTools area changed only when Chromium had created DevTools inside the key's turn
/// (ShowDevTools -> DEVTOOLS_WILL_OPEN), so the turn, and its frame, waited for that. As every create in cmux
/// (PATTERNS.md P4, instant create), the key's turn now shows a stand-in: the page takes its docked frame and the
/// DevTools area the pane's themed ground, that frame is committed, and Chromium creates DevTools in the next turn.
/// When Chromium opens nothing, the stand-in rolls back.
@MainActor @Suite(.serialized) struct CEFDevToolsStandInTests {
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
        for _ in 0..<20 { await Task.yield() }
        #expect(!ShimLog.calls.contains { $0.hasPrefix("command") }, "Chromium was never asked to open DevTools")
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

        func until(_ condition: () -> Bool) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !condition(), clock.now < deadline { await Task.yield() }
        }

        func close() {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The DevTools calls the shim got, in order (the shim is called on the main thread).
private nonisolated enum ShimLog {
    nonisolated(unsafe) static var calls: [String] = []
    /// Runs inside the show command (a Chromium that creates DevTools sends DEVTOOLS_WILL_OPEN there).
    nonisolated(unsafe) static var onShow: (@MainActor () -> Void)?

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { 29 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { browser, command, _, _ in
            let name = [CEFShimLibrary.DevToolsCommand.show: "show", CEFShimLibrary.DevToolsCommand.close: "close",
                        CEFShimLibrary.DevToolsCommand.console: "console", CEFShimLibrary.DevToolsCommand.inspect: "inspect"][command]
            ShimLog.calls.append("command \(browser) \(name ?? String(command))")
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
