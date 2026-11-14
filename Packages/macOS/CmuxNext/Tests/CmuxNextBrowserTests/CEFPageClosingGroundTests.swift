import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// CLOSE GROUND FIX (review of #37344): the ground a closing Chromium page pane shows (`CEFTab.pageGround`) is the color
/// the page area showed: none of its own (the chrome's) before the first real page, under a see-through cmux page and
/// while a committed document has not settled (the page is see-through then), then the document's own background. A page that follows
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

    /// Leo, 2026-11-07: "the loading in-between indicator shouldn't all of a sudden become opaque ... don't add some
    /// sort of weird backing to the Chromium thing to make that opaque when everything else is just the one level of
    /// transparency." A committed document that has not painted showed an opaque theme-colored page over the pane's
    /// glass. Until it paints, the page is see-through and the pane (its host, its gap, its closing ground) shows its
    /// own material, as under WebKit's hold; the document's own background takes over when it settles.
    @Test func aDocumentThatHasNotSettledShowsThePanesOwnGround() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        #expect(tab.pageGround == nil, "the closing ground is the pane's own, not an opaque loading color")
        #expect(ShimLog.transparent.last == 1, "the page draws no base while its document has not painted")
        #expect(tab.host.hostView.pageSeeThrough, "the host under the page paints no loading color")

        CEFFirstPaintBridge(tab: tab).painted()
        await rig.until { ShimLog.evaluates > 0 }
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { tab.documentSettled }
        #expect(ShimLog.transparent.last == 0, "a painted web page is opaque again, on its own color")
        #expect(!tab.host.hostView.pageSeeThrough)
        #expect(Self.argb(tab.pageGround) == Self.navy)
    }

    /// A fork without the see-through switch (API 17) keeps the page opaque on its theme base: the host, the resize gap
    /// and the closing ground take that color too, so nothing under the page claims a see-through page it is not.
    @Test func aForkWithoutTheSeeThroughSwitchKeepsTheLoadingBase() throws {
        let rig = try Rig(forkAPI: 16)
        defer { rig.close() }
        let tab = try rig.committedTab()
        #expect(ShimLog.transparent.isEmpty, "the fork has no see-through switch")
        #expect(!tab.host.hostView.pageSeeThrough)
        #expect(tab.pageGround != nil, "the pane closes on the loading base the page shows")
    }

    @Test func aSettledPageClosesOnItsOwnBackground() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try await rig.settledTab(answer: "[11,42,74]")
        #expect(Self.argb(tab.pageGround) == Self.navy)
    }

    /// A `color-scheme: dark` page with no background of its own: Blink paints its dark canvas over the white page
    /// base, so the base stays white (as Chrome's) and the pane closes on the dark canvas, not white.
    @Test func aDarkSchemePageWithNoBackgroundClosesOnTheDarkCanvasOverAWhiteBase() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try await rig.settledTab(answer: #""dark""#)
        #expect(Self.argb(tab.pageGround) == PageBackground.chromiumDarkCanvasARGB)
        #expect(ShimLog.backgrounds.last == PageBackground.engineDefaultARGB, "the page base stays Chromium's white")
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

        init(forkAPI: Int32 = 28) throws {
            ShimLog.reset()
            ShimLog.forkAPI = forkAPI
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
            let type = answer.hasPrefix("\"") ? "string" : "object"
            answerEvaluate(#"{"result":{"type":"\#(type)","value":\#(answer)}}"#)
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
    nonisolated(unsafe) static var backgrounds: [UInt32] = []
    /// Each see-through switch (fork API 17), 1 on and 0 off.
    nonisolated(unsafe) static var transparent: [Int32] = []
    nonisolated(unsafe) static var evaluates = 0
    nonisolated(unsafe) static var lastEvaluate: Int32?
    nonisolated(unsafe) static var nextMessage: Int32 = 100
    /// The fork API the fake reports (`Rig.init(forkAPI:)`).
    nonisolated(unsafe) static var forkAPI: Int32 = 28

    static func reset() {
        backgrounds = []
        transparent = []
        evaluates = 0
        lastEvaluate = nil
    }

    static func library() throws -> CEFShimLibrary {
        // Fork API 28: the tab's scripts and its color scheme go through DevTools (no renderer path).
        let version: @convention(c) () -> Int32 = { ShimLog.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let background: @convention(c) (Int32, UInt32) -> Int32 = { _, argb in
            ShimLog.backgrounds.append(argb)
            return 1
        }
        let setTransparent: @convention(c) (Int32, Int32) -> Int32 = { _, on in
            ShimLog.transparent.append(on)
            return 1
        }
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
            case "cmux_shim_tab_set_transparent_background": unsafeBitCast(setTransparent, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
