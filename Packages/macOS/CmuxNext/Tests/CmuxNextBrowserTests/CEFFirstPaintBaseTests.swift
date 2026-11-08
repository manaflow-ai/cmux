import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// BROWSER VIDEO F4 (handoff resize-videos/BROWSER-VIDEO.md, 120 Hz film bv-pane-light-dark-r2 on feat 0d19fe6,
/// 2026-11-02): navigating to a dark page in a dark theme showed the WHOLE page area white for 3 frames between the
/// theme-colored loading ground and the page's own navy paint. At the first contentful paint the page base left the
/// theme color for the document's color, but that color is read only at load end, so the base went to white first:
/// the paint signal comes before the painted frame is on screen, and the white base showed until it was. The base
/// now settles on the document's own background, read at the first paint, so it changes to a color the page itself
/// has; white only for a page with no background of its own.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFFirstPaintBaseTests {
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

    /// Review FIX at ce21bcf3454: load end arriving before the paint read answers settled white, and the read's navy
    /// was then never applied. One read serves both events and its answer applies even after the document settled.
    @Test func loadEndBeforeTheReadAnswersStillEndsOnTheDocumentsColor() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        await rig.until { ShimLog.evaluates > 0 }
        rig.runtime.handle(.loadEnd(browser: Rig.browser, httpStatus: 200))
        for _ in 0..<10 { await Task.yield() }
        #expect(ShimLog.evaluates == 1, "load end starts no second read while the paint read is in flight")
        #expect(!ShimLog.backgrounds.contains(Self.white), "no white base while the read is pending")
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { ShimLog.backgrounds.last == Self.navy }
        #expect(ShimLog.backgrounds.last == Self.navy)
        #expect(!ShimLog.backgrounds.contains(Self.white))
    }

    /// Load end with no first paint (a small page can end its load first): the same read-then-settle, never white first.
    @Test func loadEndFirstAlsoReadsBeforeSettling() async throws {
        let rig = try Rig()
        defer { rig.close() }
        _ = try rig.committedTab()
        rig.runtime.handle(.loadEnd(browser: Rig.browser, httpStatus: 200))
        await rig.until { ShimLog.evaluates > 0 }
        #expect(!ShimLog.backgrounds.contains(Self.white))
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { ShimLog.backgrounds.last == Self.navy }
        #expect(ShimLog.backgrounds.last == Self.navy)
    }

    /// Re-review FIX at fba2f6d9d61: OnLoadingStateChange(false) follows every load end and settled white at once.
    @Test func theStopLoadingEventAlsoWaitsForTheRead() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        await rig.until { ShimLog.evaluates > 0 }
        rig.runtime.handle(.loadEnd(browser: Rig.browser, httpStatus: 200))
        rig.runtime.handle(.loadingState(browser: Rig.browser, loading: false, canGoBack: false, canGoForward: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(!ShimLog.backgrounds.contains(Self.white), "no white base while the read is pending")
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { tab.documentSettled }
        #expect(ShimLog.backgrounds.last == Self.navy)
        #expect(!ShimLog.backgrounds.contains(Self.white))
    }

    /// A read that never answers (a renderer busy with page script) settles after the bounded wait, as before, and
    /// not earlier.
    @Test func aReadThatNeverAnswersSettlesAfterTheLimit() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        try await rig.clock.waitForSleeper()
        #expect(!tab.documentSettled, "the read is given its limit")
        rig.clock.advance(by: CEFTab.settleReadLimit)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))  // well under the 5 s evaluate timeout
        while !tab.documentSettled, clock.now < deadline { await Task.yield() }
        #expect(tab.documentSettled, "settled by the limit's timer")
        #expect(ShimLog.backgrounds.last == Self.white, "settled as before (no color yet)")
        // The read is still pending (a timed-out read's answer would be dropped): its late answer applies to the
        // already-settled document, never left white for the document's life.
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { ShimLog.backgrounds.last == Self.navy }
        #expect(ShimLog.backgrounds.last == Self.navy, "the late answer applies after the timer settled")
    }

    /// Load end on a settled document reads its background again (a page that turns dark after its first paint).
    @Test func loadEndAfterTheAnswerReadsTheColorAgain() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        await rig.until { ShimLog.evaluates > 0 }
        rig.answerEvaluate(#"{"result":{"type":"object","value":[255,255,255]}}"#)
        await rig.until { tab.documentSettled }
        rig.runtime.handle(.loadEnd(browser: Rig.browser, httpStatus: 200))
        await rig.until { ShimLog.evaluates == 2 }
        #expect(ShimLog.evaluates == 2, "load end on a settled document reads again")
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { ShimLog.backgrounds.last == Self.navy }
        #expect(ShimLog.backgrounds.last == Self.navy, "the later color applies")
    }

    /// Load end during the in-flight paint read: one more read follows the answer, so a background set between the
    /// paint and the load end is still seen.
    @Test func loadEndDuringTheReadOwesOneMoreRead() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let tab = try rig.committedTab()
        CEFFirstPaintBridge(tab: tab).painted()
        await rig.until { ShimLog.evaluates > 0 }
        rig.runtime.handle(.loadEnd(browser: Rig.browser, httpStatus: 200))
        for _ in 0..<10 { await Task.yield() }
        #expect(ShimLog.evaluates == 1, "one read in flight at a time")
        rig.answerEvaluate(#"{"result":{"type":"object","value":[255,255,255]}}"#)
        await rig.until { ShimLog.evaluates == 2 }
        #expect(ShimLog.evaluates == 2, "the owed read follows the answer")
        rig.answerEvaluate(#"{"result":{"type":"object","value":[11,42,74]}}"#)
        await rig.until { ShimLog.backgrounds.last == Self.navy }
        #expect(ShimLog.backgrounds.last == Self.navy)
        #expect(tab.documentSettled)
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
        #expect(tab.documentSettled, "the failed read settles at once (the manual clock never reached the limit)")
    }

    // MARK: Rig

    @MainActor final class Rig {
        static let browser: Int32 = 19
        /// The settle wait's clock: no test waits for real time; one advances it past the limit on purpose.
        let clock = ManualClock()
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
            tab.settleTimer = DemandTimer(owner: "test", clock: clock)
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
            // Closed, not only emptied: a window never closed is left open (`.closesItsWindows`).
            window.closeAfterTest()
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
