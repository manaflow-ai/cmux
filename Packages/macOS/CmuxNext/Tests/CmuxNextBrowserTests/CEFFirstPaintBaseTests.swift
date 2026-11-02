import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// BROWSER VIDEO F4 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz film bv-pane-light-dark-r2 on feat 0d19fe6,
/// 2026-11-02): navigating to a dark page in a dark theme showed the WHOLE page area white for 3 frames between the
/// theme-colored loading ground and the page's own navy paint. At the first contentful paint the page base left the
/// theme color for the document's color, but that color is read only at load end, so the base went to white first:
/// the paint signal comes before the painted frame is on screen, and the white base showed until it was. The base
/// now settles on the document's own background, read at the first paint, so it changes to a color the page itself
/// has; white only for a page with no background of its own.
@MainActor @Suite(.serialized) struct CEFFirstPaintBaseTests {
    static let white: UInt32 = 0xFFFF_FFFF
    static let navy: UInt32 = 0xFF0B_2A4A

    @Test func theFirstPaintSettlesTheBaseOnTheDocumentsColorNeverWhiteFirst() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        #expect(!ShimLog.backgrounds.contains(Self.white), "no white base while the document's color is unknown")
        await rig.until { ShimLog.evaluates > 0 }
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { ShimLog.backgrounds.contains(Self.navy) }
        #expect(ShimLog.backgrounds.last == Self.navy, "the base settles on the page's own navy")
        #expect(!ShimLog.backgrounds.contains(Self.white), "and never passes through white")
    }

    /// A page with no background of its own is white, the web default.
    @Test func aPageWithNoBackgroundSettlesWhite() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        await rig.until { ShimLog.evaluates > 0 }
        rig.answerEvaluate(#"{"result":{"type":"object","value":[255,255,255]}}"#)
        await rig.until { ShimLog.backgrounds.last == Self.white }
        #expect(ShimLog.backgrounds.last == Self.white)
    }

    /// The read fails (the page went away): the document still owns the page area.
    @Test func aFailedReadStillSettles() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        await rig.until { ShimLog.evaluates > 0 }
        rig.answerEvaluate(#"{"exceptionDetails":{"text":"gone"}}"#, success: false)
        await rig.until { tab.documentSettled }
        #expect(tab.documentSettled)
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 19
        let runtime: CEFRuntime
        let root: URL
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)

        init() throws {
            ShimLog.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-first-paint-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try ShimLog.library(), storage: CEFProfileStorage(root: root))
        }

        /// A shown tab whose real page committed (OnLoadStart) and has not painted yet.
        func committedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: Self.browser, request: request, window: 1))
            try #require(tab.browserID == Self.browser)
            tab.container.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.addSubview(tab.container)
            runtime.handle(.loadStart(browser: Self.browser, url: "http://127.0.0.1:8000/dark.html", fromPost: false))
            try #require(!tab.documentSettled)
            ShimLog.backgrounds = []
            return tab
        }

        func answerEvaluate(_ json: String, success: Bool = true) {
            guard let message = ShimLog.lastEvaluate else { return }
            runtime.handle(.devToolsResult(browser: Self.browser, messageID: message, success: success, json: json))
        }

        func until(_ condition: () -> Bool) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !condition(), clock.now < deadline { await Task.yield() }
        }

        func close() {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            try? FileManager.default.removeItem(at: root)
            // The runtime is `unowned` in its tabs and hosts, and a tab shown in a window outlives the test's locals
            // (its views, the window): ending the runtime first crashed the run at teardown on the fleet ("read an
            // unowned reference ... already destroyed"). Each rig lives to the end of the test process.
            Self.kept.append(self)
        }

        /// Rigs kept alive (see `close`).
        static var kept: [Rig] = []
    }
}

/// What the fake shim was asked (the shim is called on the main thread).
private nonisolated enum ShimLog {
    nonisolated(unsafe) static var backgrounds: [UInt32] = []
    nonisolated(unsafe) static var evaluates = 0
    nonisolated(unsafe) static var lastEvaluate: Int32?
    nonisolated(unsafe) static var nextMessage: Int32 = 100

    static func reset() {
        backgrounds = []
        evaluates = 0
        lastEvaluate = nil
    }

    static func library() throws -> CEFShimLibrary {
        // Fork API 28: the tab's own scripts go through DevTools Runtime.evaluate (no renderer path).
        let version: @convention(c) () -> Int32 = { 28 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let background: @convention(c) (Int32, UInt32) -> Int32 = { _, argb in
            ShimLog.backgrounds.append(argb)
            return 1
        }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, params in
            ShimLog.nextMessage += 1
            // Only the page-background read (`CEFTab.pageBackdropScript`); the tab's other set-up calls are not it.
            if method.map({ String(cString: $0) }) == "Runtime.evaluate",
               params.map({ String(cString: $0) })?.contains("willReadFrequently") == true {
                ShimLog.evaluates += 1
                ShimLog.lastEvaluate = ShimLog.nextMessage
            }
            return ShimLog.nextMessage
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_background_color": unsafeBitCast(background, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
