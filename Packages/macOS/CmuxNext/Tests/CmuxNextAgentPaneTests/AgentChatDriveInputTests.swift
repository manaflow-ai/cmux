import AppKit
@testable import CmuxNextAgentPane
import CmuxNextTestSupport
import Testing
import WebKit

/// `agent.chat.drive`'s input (``AgentChatDriveInput``) is the engine's own: a move hands WebKit an
/// AppKit event, so the page gets trusted pointer and mouse events and real CSS `:hover` (a style only a
/// `:hover` rule sets applies), and a wheel tick is a trusted `wheel` that scrolls the box under the
/// held point. Nothing reaches the window server: the person's pointer stays where it is, and the
/// window never becomes key, is never ordered front and never comes to the front.
@MainActor
@Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2)))
struct AgentChatDriveInputTests {
    static let html = """
    <!doctype html><html><head><style>
      body { margin: 0; font: 14px sans-serif; }
      #list { position: absolute; left: 20px; top: 20px; width: 300px; height: 200px; overflow: auto; }
      #box { height: 60px; margin: 10px; outline: 2px solid rgb(9, 9, 9); }
      #box:hover { outline-color: rgb(1, 2, 3); }
      #filler { height: 3000px; }
    </style></head><body><div id="list"><div id="box">hover me</div><div id="filler"></div></div><script>
      window.log = [];
      for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'mousemove', 'wheel']) {
        document.addEventListener(type, (e) => window.log.push({ type, trusted: e.isTrusted,
          id: e.target.id || '', deltaY: e.deltaY ?? null }), true);
      }
    </script></body></html>
    """

    final class Page {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)

        init() async throws {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            window.contentView = webView
            webView.loadHTMLString(AgentChatDriveInputTests.html, baseURL: nil)
            try await until("the page loaded") { try await self.read("document.readyState === 'complete' && !!document.getElementById('box')") as? Bool == true }
        }

        func read(_ expression: String) async throws -> Any? {
            try await webView.callAsyncJavaScript("return \(expression);", arguments: [:], in: nil, contentWorld: .page)
        }

        func until(_ what: String, _ condition: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !((try? await condition()) ?? false), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let log = (try? await read("JSON.stringify(window.log)")) as? String ?? ""
            try #require(try await condition(), "\(what) never happened; the page saw \(log)")
        }

        /// The box's middle, in viewport CSS px.
        func boxCenter() async throws -> CGPoint {
            let text = try #require(try await read("JSON.stringify((() => { const r = document.getElementById('box').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })())") as? String)
            let point = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Double])
            return CGPoint(x: point[0], y: point[1])
        }

        func events(_ type: String) async throws -> [[String: Any]] {
            let text = try #require(try await read("JSON.stringify(window.log.filter((e) => e.type === '\(type)'))") as? String)
            return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        }

        var hoverStyle: String {
            get async throws { try await read("getComputedStyle(document.getElementById('box')).outlineColor") as? String ?? "" }
        }
    }

    /// The capture-slot case: a window that was never ordered in, never key. The move gives the box
    /// trusted pointer and mouse events and its `:hover` style; the release takes the hover away.
    @Test func aMoveHoversTheBoxWithTrustedEventsAndTheReleaseDropsIt() async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        let pointer = NSEvent.mouseLocation
        let input = AgentChatDriveInput(webView: page.webView)
        let center = try await page.boxCenter()

        #expect(await input.move(to: center))
        await input.settle()
        try await page.until("the box is hovered") { try await page.read("document.getElementById('box').matches(':hover')") as? Bool == true }
        #expect(try await page.hoverStyle == "rgb(1, 2, 3)", "only the :hover rule sets this outline color")
        for type in ["pointerover", "pointerenter", "mouseover", "mouseenter", "mousemove"] {
            let seen = try await page.events(type)
            #expect(!seen.isEmpty, "no \(type)")
            #expect(seen.allSatisfy { $0["trusted"] as? Bool == true }, "\(type) was not trusted: \(seen)")
        }

        #expect(await input.release() == .wentIn)
        await input.settle()
        try await page.until("the hover dropped") { try await page.read("document.getElementById('box').matches(':hover')") as? Bool == false }
        #expect(try await page.hoverStyle == "rgb(9, 9, 9)")

        #expect(NSEvent.mouseLocation == pointer, "the person's pointer moved")
        #expect(!page.window.isKeyWindow)
        #expect(!page.window.isVisible, "the window was ordered in")
    }

    /// A release that says it went in has been handled by WebKit already: the box is no longer hovered
    /// the moment `release()` returns, with no settle and no waiting, so the drive never stops retrying
    /// while a late event could still leave `:hover` on.
    @Test func aReleaseThatWentInHasDroppedTheHoverWhenItReturns() async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        let input = AgentChatDriveInput(webView: page.webView)
        let center = try await page.boxCenter()
        #expect(await input.move(to: center))
        await input.settle()
        try await page.until("the box is hovered") { try await page.read("document.getElementById('box').matches(':hover')") as? Bool == true }

        #expect(await input.release() == .wentIn)
        #expect(try await page.read("document.getElementById('box').matches(':hover')") as? Bool == false,
                "release() returned before WebKit handled its move")
    }

    /// A release whose wait for WebKit's pending mouse events ran out has not gone in: WebKit may still
    /// handle the move later, or never, so the release says `.failed` and DriveRelease keeps retrying.
    /// One WebKit answered went in; one it can't tell about (nil: an unverified macOS) counts as sent.
    @Test(arguments: [(Bool?.some(false), AgentChatDriveInput.ReleaseOutcome.failed), (true, .wentIn), (nil, .wentIn)])
    func aReleaseWhoseWaitRanOutHasNotGoneIn(wait: Bool?, outcome: AgentChatDriveInput.ReleaseOutcome) async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        var input = AgentChatDriveInput(webView: page.webView)
        #expect(await input.move(to: try await page.boxCenter()))
        input.pendingMouseEvents = { _, _ in wait }
        #expect(await input.release() == outcome)
    }

    /// A wait is cut to the run's time left, and with none left there is no wait.
    @Test func aWaitIsCutToTheTimeLeft() {
        let now = ContinuousClock.now
        let bound = AgentChatDriveInput.wheelWait
        #expect(AgentChatDriveInput.bounded(bound, before: nil, now: now) == bound)
        #expect(AgentChatDriveInput.bounded(bound, before: now + .seconds(5), now: now) == bound)
        #expect(AgentChatDriveInput.bounded(bound, before: now + .milliseconds(120), now: now) == .milliseconds(120))
        #expect(AgentChatDriveInput.bounded(bound, before: now, now: now) == nil)
        #expect(AgentChatDriveInput.bounded(bound, before: now - .seconds(1), now: now) == nil)
    }

    /// A tick's two WebKit waits (its presentation update, then its pending events) can't outlast the run:
    /// on a covered window each would run its whole bound, so 200 ticks went about 200 s past `seconds`.
    /// Each is cut to the time the run has left, and a tick with none left sends without waiting.
    @Test func aTicksWaitsAreBoundedByTheRunsTimeLeft() async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        var input = AgentChatDriveInput(webView: page.webView)
        var waits: [Duration] = []
        input.presentationUpdate = { _, bound in
            waits.append(bound)
            return true
        }
        input.pendingMouseEvents = { _, bound in
            waits.append(bound)
            return true
        }
        let center = try await page.boxCenter()

        #expect(await input.wheel(at: center, deltaY: 40, before: ContinuousClock.now + .milliseconds(100)))
        #expect(waits.count == 2 && waits.allSatisfy { $0 > .zero && $0 <= .milliseconds(100) }, "\(waits)")
        waits = []
        #expect(await input.wheel(at: center, deltaY: 40, before: ContinuousClock.now - .milliseconds(1)))
        #expect(waits.isEmpty, "a tick with no time left waited \(waits)")
        waits = []
        #expect(await input.wheel(at: center, deltaY: 40))
        #expect(waits == [AgentChatDriveInput.wheelWait, AgentChatDriveInput.wheelWait])
    }

    /// A tick records what each WebKit wait took and how it ended: answered, its bound ran out, or
    /// nothing is known (no SPI). A wait with no time left is skipped and recorded as none.
    @Test func aTickRecordsWhatEachWaitTookAndHowItEnded() async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        var input = AgentChatDriveInput(webView: page.webView)
        input.presentationUpdate = { _, _ in false }
        input.pendingMouseEvents = { _, _ in nil }
        let center = try await page.boxCenter()

        let tick = await input.wheelTick(at: center, deltaY: 40, before: ContinuousClock.now + .seconds(5))
        #expect(tick.sent)
        #expect(tick.presentation?.how == .bound)
        #expect(tick.pending?.how == .unknown)
        #expect((tick.presentation?.milliseconds ?? -1) >= 0 && (tick.pending?.milliseconds ?? -1) >= 0)
        input.presentationUpdate = { _, _ in true }
        input.pendingMouseEvents = { _, _ in true }
        let answered = await input.wheelTick(at: center, deltaY: 40, before: nil)
        #expect(answered.presentation?.how == .answered && answered.pending?.how == .answered)
        let late = await input.wheelTick(at: center, deltaY: 40, before: ContinuousClock.now - .milliseconds(1))
        #expect(late.sent && late.presentation == nil && late.pending == nil)
    }

    /// The pause between ticks ends `tick_ms` after the tick started, not after its waits: a tick whose
    /// waits took 10 of 16 ms pauses 6, one that took 20 goes on at once, and none passes the run's end.
    @Test func thePauseIsAnchoredToTheTicksStart() {
        let started = ContinuousClock.now
        let stop = started + .seconds(10)
        #expect(DriveCadence.nextTick(after: started, every: .milliseconds(16), stop: stop) == started + .milliseconds(16))
        #expect(DriveCadence.nextTick(after: started, every: .milliseconds(16), stop: started + .milliseconds(5))
            == started + .milliseconds(5))
        #expect(DriveCadence.pause(until: started + .milliseconds(16), now: started + .milliseconds(10)) == .milliseconds(6))
        #expect(DriveCadence.pause(until: started + .milliseconds(16), now: started + .milliseconds(20)) == .zero)
    }

    /// The settle after the last tick can't outlast the run either: its two 1 s waits ran whole after the
    /// ticks had reached `seconds`, so an occluded run ended about 2 s late. Each is cut to the time left,
    /// and with none left the run reads the page without waiting.
    @Test func theSettleAfterTheTicksIsBoundedByTheRunsTimeLeft() async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        var input = AgentChatDriveInput(webView: page.webView)
        var waits: [Duration] = []
        input.presentationUpdate = { _, bound in
            waits.append(bound)
            return true
        }
        input.pendingMouseEvents = { _, bound in
            waits.append(bound)
            return true
        }

        await input.settle(before: ContinuousClock.now + .milliseconds(100))
        #expect(waits.count == 2 && waits.allSatisfy { $0 > .zero && $0 <= .milliseconds(100) }, "\(waits)")
        waits = []
        await input.settle(before: ContinuousClock.now - .milliseconds(1))
        #expect(waits.isEmpty, "a settle with no time left waited \(waits)")
        waits = []
        await input.settle()
        #expect(waits == [.seconds(1), .seconds(1)])
    }

    /// A wheel tick under the held point is one trusted `wheel` with the tick's sign, and the box
    /// under it scrolls. WebKit holds a native wheel for a window that cannot present, so the window
    /// is on a screen: ordered in behind every other window (never front, never key).
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "needs a display"))
    func aWheelTickUnderTheHeldPointScrollsTheBoxWithATrustedWheel() async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        page.window.orderBack(nil)
        try #require(page.window.screen != nil)
        let pointer = NSEvent.mouseLocation
        let input = AgentChatDriveInput(webView: page.webView)
        let center = try await page.boxCenter()

        #expect(await input.move(to: center))
        await input.settle()
        try await page.until("the box is hovered") { try await page.read("document.getElementById('box').matches(':hover')") as? Bool == true }
        #expect(await input.wheel(at: center, deltaY: 120))
        await input.settle()
        try await page.until("the list scrolled") {
            (try await page.read("document.getElementById('list').scrollTop") as? Double ?? 0) > 0
        }
        let wheels = try await page.events("wheel")
        #expect(!wheels.isEmpty)
        #expect(wheels.allSatisfy { $0["trusted"] as? Bool == true }, "\(wheels)")
        #expect(wheels.allSatisfy { ($0["deltaY"] as? Double ?? 0) > 0 }, "a positive tick scrolls down: \(wheels)")
        _ = await input.release()

        #expect(NSEvent.mouseLocation == pointer, "the person's pointer moved")
        #expect(!page.window.isKeyWindow)
        #expect(NSApp.orderedWindows.first !== page.window || NSApp.orderedWindows.count == 1, "the window came to the front")
    }

    /// Thirty ticks 1 ms apart (less than a frame) each reach the page: the list moves exactly 30 × the
    /// delta and the page sees 30 trusted wheels, so a drive's `delivered` and `scrolled` are true.
    /// Without the per-tick wait for WebKit's presentation update, ticks are dropped or coalesced.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "needs a display"))
    func thirtyTicksAMillisecondApartScrollExactlyThirtyTimesTheDelta() async throws {
        let page = try await Page()
        defer { page.window.closeAfterTest() }
        page.window.orderBack(nil)
        try #require(page.window.screen != nil)
        let input = AgentChatDriveInput(webView: page.webView)
        let center = try await page.boxCenter()
        #expect(await input.move(to: center))
        await input.settle()
        let delta = 40.0
        for _ in 0..<30 {
            #expect(await input.wheel(at: center, deltaY: delta))
            // wakeup-allow: the test's own 1 ms tick spacing, 30 ticks
            try await Task.sleep(for: .milliseconds(1))
        }
        await input.settle()
        try await page.until("the list moved 30 ticks") {
            (try await page.read("document.getElementById('list').scrollTop") as? Double ?? 0) >= 30 * delta
        }
        await input.settle()
        #expect(try await page.read("document.getElementById('list').scrollTop") as? Double == 30 * delta)
        let wheels = try await page.events("wheel")
        #expect(wheels.count == 30, "the page saw \(wheels.count) wheels")
        #expect(wheels.allSatisfy { $0["trusted"] as? Bool == true })
        _ = await input.release()
    }
}
