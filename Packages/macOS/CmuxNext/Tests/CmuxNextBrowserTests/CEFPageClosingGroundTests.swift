import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// CLOSE GROUND FIX (review of #37344): the ground a closing Chromium page pane shows (`CEFTab.pageGround`) is the color
/// the page area showed: none of its own (the chrome's) before the first real page and under a see-through cmux page, the
/// loading base while a committed document has not settled, then the document's own background. A page that follows
/// `prefers-color-scheme` changes that background when cmux's appearance changes, so the scheme change reads it again;
/// before, it was read only at load end and at a window live-resize start, and the pane closed on the old color.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFPageClosingGroundTests {
    static let navy: UInt32 = 0xFF0B_2A4A

    static func argb(_ color: CGColor?) -> UInt32? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return PageBackground.argb(srgb)
    }

    /// The one rule both engines' closing ground and Chromium's resize gap use.
    @Test func theSharedRule() {
        let rule = PageBackground.closingGroundARGB
        #expect(rule(false, true, nil, Self.navy, 0xFFFF_FFFF) == nil, "no real page: the chrome's ground")
        #expect(rule(true, false, 0xFF22_2222, Self.navy, 0xFFFF_FFFF) == 0xFF22_2222, "not settled: the loading base")
        #expect(rule(true, false, nil, Self.navy, 0xFFFF_FFFF) == nil, "not settled, no base painted: the chrome's ground")
        #expect(rule(true, true, 0xFF22_2222, Self.navy, 0xFFFF_FFFF) == Self.navy, "settled: the document's own")
        #expect(rule(true, true, nil, nil, PageBackground.webKitDarkCanvasARGB) == PageBackground.webKitDarkCanvasARGB,
                "settled with no background of its own: the canvas, never nil (the window's color)")
    }

    @Test func beforeTheFirstRealPageThePaneKeepsTheChromesGround() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        #expect(tab.pageGround == nil)
    }

    @Test func aDocumentThatHasNotSettledClosesOnTheLoadingBase() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        #expect(Self.argb(tab.pageGround) == PageBackground.themeARGB(in: tab.container))
    }

    @Test func aSettledPageClosesOnItsOwnBackground() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try await rig.settledTab(answer: "[11,42,74]")
        #expect(Self.argb(tab.pageGround) == Self.navy)
    }

    @Test func aSeeThroughCmuxPageKeepsThePanesGround() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try await rig.settledTab(answer: "[11,42,74]")
        tab.pageSeeThrough = true
        #expect(tab.pageGround == nil)
    }

    /// A page that follows `prefers-color-scheme`, light when it loaded; cmux's appearance turns dark: the scheme the
    /// page hears changes, and its background is read again, so the pane closes on the page's dark color.
    @Test func aColorSchemeChangeReadsThePagesBackgroundAgain() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try await rig.settledTab(answer: "[250,250,250]")
        // Light first, whatever the test host's appearance is, so the next change is a real one.
        tab.applyColorScheme(.light)
        await rig.until(seconds: 1) { ShimLog.evaluates > 1 }
        if ShimLog.evaluates > 1 { rig.answerEvaluate(#"{"result":{"type":"object","value":[250,250,250]}}"#) }
        await rig.until(seconds: 1) { Self.argb(tab.pageGround) == 0xFFFA_FAFA }
        try #require(Self.argb(tab.pageGround) == 0xFFFA_FAFA, "SETUP: the light page did not settle")
        let reads = ShimLog.evaluates

        tab.applyColorScheme(.dark)
        await rig.until { ShimLog.evaluates > reads }
        #expect(ShimLog.evaluates == reads + 1, "the scheme change reads the page's background again")
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { Self.argb(tab.pageGround) == Self.navy }
        #expect(Self.argb(tab.pageGround) == Self.navy, "the pane closes on the page's dark color, not the light one")
    }

    // MARK: Rig (as CEFFirstPaintBaseTests')

    @MainActor final class Rig {
        static let browser: Int32 = 23
        let clock = ManualClock()
        let runtime: CEFRuntime
        let root: URL
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)

        init() throws {
            ShimLog.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-closing-ground-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try ShimLog.library(), storage: CEFProfileStorage(root: root))
        }

        /// A shown tab whose browser exists and that has committed no document yet.
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
            tab.settleTimer = DemandTimer(owner: "test", clock: clock)
            return tab
        }

        /// A shown tab whose real page committed (OnLoadStart) and has not painted yet.
        func committedTab() throws -> CEFTab {
            let tab = try attachedTab()
            runtime.handle(.loadStart(browser: Self.browser, url: "http://127.0.0.1:8000/page.html", fromPost: false))
            try #require(!tab.documentSettled)
            return tab
        }

        /// A committed tab whose first paint read its background (`answer`, `[r, g, b]`) and settled on it.
        func settledTab(answer: String) async throws -> CEFTab {
            let tab = try committedTab()
            CEFFirstPaintBridge(tab: tab).painted()
            await until { ShimLog.evaluates > 0 }
            try #require(ShimLog.evaluates == 1, "SETUP: the first paint read no background")
            answerEvaluate(#"{"result":{"type":"object","value":\#(answer)}}"#)
            await until { tab.documentSettled }
            try #require(tab.documentSettled, "SETUP: the page did not settle")
            return tab
        }

        func answerEvaluate(_ json: String, success: Bool = true) {
            guard let message = ShimLog.lastEvaluate else { return }
            runtime.handle(.devToolsResult(browser: Self.browser, messageID: message, success: success, json: json))
        }

        func until(seconds: Int = 10, _ condition: () -> Bool) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(seconds))
            while !condition(), clock.now < deadline { await Task.yield() }
        }

        func close() {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.closeAfterTest()
            try? FileManager.default.removeItem(at: root)
            // The runtime is `unowned` in its tabs and hosts: each rig lives to the end of the test process
            // (CEFFirstPaintBaseTests.Rig.close).
            Self.kept.append(self)
        }

        static var kept: [Rig] = []
    }
}

/// What the fake shim was asked (the shim is called on the main thread).
private nonisolated enum ShimLog {
    nonisolated(unsafe) static var evaluates = 0
    nonisolated(unsafe) static var lastEvaluate: Int32?
    nonisolated(unsafe) static var nextMessage: Int32 = 100

    static func reset() {
        evaluates = 0
        lastEvaluate = nil
    }

    static func library() throws -> CEFShimLibrary {
        // Fork API 28: the tab's scripts and its color scheme go through DevTools (no renderer path).
        let version: @convention(c) () -> Int32 = { 28 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let background: @convention(c) (Int32, UInt32) -> Int32 = { _, _ in 1 }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, method, params in
            ShimLog.nextMessage += 1
            // Only the page-background read (`CEFTab.pageBackdropScript`); the tab's other calls are not it.
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
