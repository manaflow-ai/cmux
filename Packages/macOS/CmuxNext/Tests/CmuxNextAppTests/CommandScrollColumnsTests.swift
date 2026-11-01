import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeupsTestSupport
import CmuxNextTestSupport
import CoreGraphics
import Testing

/// Command + scroll pans the columns (Lawrence 2026-10-28: "if i hold cmd scroll, it still scrolls
/// terminal, idk if that is ideal behavior. but we also want to handle websites like figma or
/// excalidraw that try to handle cmd scroll ... like cmd scroll for columns").
///
/// - Over a terminal or any other pane that is not a web page, a Command scroll on a columns screen
///   is always the layout's, also when the strip fits (it rubber-bands): the pane never scrolls.
/// - Over a web page's own window, the layout holds the Command scroll and asks the page
///   (``PageCommandScrollArbiter``). A page that cancels the wheel event (Figma, Excalidraw zoom)
///   gets the held events and keeps the gesture; otherwise the columns pan with them.
@MainActor
@Suite(.closesItsWindows)
struct CommandScrollColumnsTests {
    typealias Base = LayoutScrollModifierTests

    /// A page's own window that records what is sent to it: the held events a page keeps.
    final class RecordingPageWindow: NSWindow {
        var received: [NSEvent] = []
        override func sendEvent(_ event: NSEvent) { received.append(event) }
    }

    /// Answers every ask with `answer`, or, with `waits`, only when the test calls ``release``.
    final class FakeArbiter: PageCommandScrollArbiter {
        var answer: Bool
        let waits: Bool
        var asks: [NSPoint] = []
        private var pending: [CheckedContinuation<Bool, Never>] = []
        /// Set by ``release``: an ask that starts after it answers at once.
        private var released = false

        init(answer: Bool, waits: Bool = false) {
            self.answer = answer
            self.waits = waits
        }

        func pageHandlesCommandScroll(in window: NSWindow, at locationInWindow: NSPoint) async -> Bool {
            asks.append(locationInWindow)
            guard waits, !released else { return answer }
            return await withCheckedContinuation { pending.append($0) }
        }

        func release() {
            released = true
            for continuation in pending { continuation.resume(returning: answer) }
            pending = []
        }
    }

    final class Harness {
        let provider = Base.Panes()
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var pages: [NSWindow] = []
        /// The layout's deadline clock: the page's answer deadline moves only when a test advances it.
        let clock = ManualClock()
        private let arbiter: FakeArbiter?

        init(model: LayoutModel, arbiter: FakeArbiter? = nil) {
            self.arbiter = arbiter
            window.isReleasedWhenClosed = false
            root = LayoutRootView(model: model, contentProvider: provider, scrollbarClock: clock, pageCommandScroll: arbiter)
            root.context.reduceMotionOverride = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        /// End pending probes and close the windows even when a throwing assertion exits early.
        func close() {
            root.pageProbe = nil
            root.pageProbeTimer.cancel()
            root.pageProbeTask?.cancel()
            arbiter?.release()
            for page in pages {
                window.removeChildWindow(page)
                page.close()
            }
            pages.removeAll()
            window.contentView = nil
            window.close()
        }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        /// A recording page window over `pane`, as a Chromium page sits over its pane.
        func page(over pane: PaneID) throws -> RecordingPageWindow {
            let page = RecordingPageWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            Base.attach(page, to: window, over: root.convert(try #require(root.frame(of: pane)), to: nil))
            pages.append(page)
            return page
        }

        func settle() { for _ in 0..<600 { if !root.advanceFrame(1.0 / 120) { break } } }

        /// Waits for the page's answer to be applied.
        func answered() async {
            await root.pageProbeTask?.value
        }
    }

    /// One column that fills the screen: the strip fits, nothing scrolls.
    static func oneColumn() -> LayoutModel {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: "c1", width: 1, root: .leaf("a")),
        ]))], activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        model.scrollModifierOverride = .command
        return model
    }

    /// Two half columns, `b` focused: the strip fits.
    static func twoFittingColumns() -> LayoutModel {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("b")),
        ]))], activeScreenID: "s", focusedPane: "b")
        model.followsDesignMetrics = false
        model.scrollModifierOverride = .command
        return model
    }

    // MARK: terminals and other panes

    /// The user's repro: Command + a trackpad scroll over a terminal in a workspace whose columns
    /// fit. The terminal scrolled; now the layout takes every event, momentum included, the strip
    /// follows the fingers (rubber band) and springs back where it was.
    @Test func aCommandSwipeOverATerminalWhereTheStripFitsIsTheLayouts() throws {
        let h = Harness(model: Self.oneColumn())
        defer { h.close() }
        let point = try h.center("a")
        let before = try #require(h.root.frame(of: "a"))
        let strip = try #require(h.root.screenViews["s"])
        #expect(Base.scroll(h.root, at: point, phase: .mayBegin, command: true), "the terminal never sees the touch")
        #expect(h.root.ownsCurrentScrollGesture)
        #expect(Base.scroll(h.root, at: point, dx: -30, phase: .began, command: true))
        for _ in 0..<3 { #expect(Base.scroll(h.root, at: point, dx: -30, phase: .changed, command: true)) }
        #expect(strip.isUserScrolling, "the strip follows the fingers")
        #expect(Base.scroll(h.root, at: point, phase: .ended, command: true))
        #expect(Base.scroll(h.root, at: point, dx: -10, momentum: .begin, command: true), "the coast is the layout's")
        #expect(Base.scroll(h.root, at: point, momentum: .end, command: true))
        h.settle()
        #expect(h.root.frame(of: "a") == before, "a strip that fits springs back")
    }

    @Test func aCommandVerticalSwipeAndWheelOverATerminalWhereTheStripFitsAreTheLayouts() throws {
        let h = Harness(model: Self.oneColumn())
        defer { h.close() }
        let point = try h.center("a")
        #expect(Base.scroll(h.root, at: point, dy: -30, phase: .began, command: true), "up and down too")
        #expect(Base.scroll(h.root, at: point, dy: -30, phase: .changed, command: true))
        #expect(Base.scroll(h.root, at: point, phase: .ended, command: true))
        #expect(Base.scroll(h.root, at: point, dy: -1, units: .line, command: true), "a wheel notch")
        #expect(Base.scroll(h.root, at: point, dx: -1, units: .line, command: true), "a sideways notch")
        #expect(!Base.scroll(h.root, at: point, dy: -1, units: .line), "a plain notch is still the terminal's")
    }

    /// Two columns that fit, the second focused: a Command swipe rubber-bands and leaves focus.
    @Test func aCommandSwipeOverFittingColumnsKeepsFocusAndPlace() throws {
        let h = Harness(model: Self.twoFittingColumns())
        defer { h.close() }
        let point = try h.center("b")
        let before = try #require(h.root.frame(of: "b"))
        #expect(Base.scroll(h.root, at: point, dx: 40, phase: .began, command: true))
        for _ in 0..<3 { #expect(Base.scroll(h.root, at: point, dx: 40, phase: .changed, command: true)) }
        #expect(Base.scroll(h.root, at: point, phase: .ended, command: true))
        h.settle()
        #expect(h.root.frame(of: "b") == before)
        #expect(h.root.model.focusedPane == "b", "nothing to reveal, so focus stays")
    }

    // MARK: browser panes where the strip fits

    /// Lawrence 2026-10-28: "if focus mode for browser is on, then we need to make sure cmd scrolls
    /// for scrolling columns/rows, doesnt work if mouse is hovered over a browser". Focus mode gives
    /// the page the keyboard, not the Command scroll: over a browser pane whose columns fit, a
    /// Command swipe is the layout's as it is over a terminal (rubber band, spring back), once the
    /// page says it does not use Command + scroll.
    @Test func aCommandSwipeOverABrowserWhereTheStripFitsIsTheLayouts() async throws {
        let arbiter = FakeArbiter(answer: false)
        let h = Harness(model: Self.twoFittingColumns(), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "b")
        let point = try h.center("b")
        let before = try #require(h.root.frame(of: "b"))
        let strip = try #require(h.root.screenViews["s"])
        #expect(Base.scroll(h.root, from: page, at: point, phase: .mayBegin, command: true), "the page never sees the touch")
        #expect(Base.scroll(h.root, from: page, at: point, dx: 40, phase: .began, command: true))
        await h.answered()
        #expect(arbiter.asks.count == 1, "the page is still asked first")
        #expect(h.root.ownsCurrentScrollGesture)
        for _ in 0..<3 { #expect(Base.scroll(h.root, from: page, at: point, dx: 40, phase: .changed, command: true)) }
        #expect(strip.isUserScrolling, "the strip follows the fingers")
        #expect(Base.scroll(h.root, from: page, at: point, phase: .ended, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: 10, momentum: .begin, command: true), "the coast is the layout's")
        #expect(Base.scroll(h.root, from: page, at: point, momentum: .end, command: true))
        #expect(page.received.isEmpty, "the page goes neither Back nor Forward")
        h.settle()
        #expect(h.root.frame(of: "b") == before, "a strip that fits springs back")
    }

    /// The same over one full-width browser column, up and down and with a wheel notch.
    @Test func aCommandWheelOverABrowserWhereTheStripFitsIsTheLayouts() async throws {
        let arbiter = FakeArbiter(answer: false)
        let h = Harness(model: Self.oneColumn(), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "a")
        let point = try h.center("a")
        #expect(Base.scroll(h.root, from: page, at: point, dy: -1, units: .line, command: true), "a Command notch is held")
        await h.answered()
        #expect(page.received.isEmpty, "and never reaches the page")
        #expect(!Base.scroll(h.root, from: page, at: point, dy: -1, units: .line), "a plain notch is still the page's")
    }

    /// With `layout.pagesHandleCommandScroll` off the layout takes it at once, strip fitting or not.
    @Test func withPagesFirstOffACommandSwipeOverABrowserWhereTheStripFitsIsTheLayoutsAtOnce() throws {
        let arbiter = FakeArbiter(answer: true)
        let model = Self.oneColumn()
        model.pagesHandleCommandScrollOverride = false
        let h = Harness(model: model, arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "a")
        let point = try h.center("a")
        #expect(Base.scroll(h.root, from: page, at: point, dy: -30, phase: .began, command: true))
        #expect(h.root.ownsCurrentScrollGesture)
        #expect(Base.scroll(h.root, from: page, at: point, phase: .ended, command: true))
        #expect(arbiter.asks.isEmpty)
        #expect(page.received.isEmpty)
    }

    /// Figma or Excalidraw in a browser whose columns fit keeps its Command + scroll zoom.
    @Test func aPageThatHandlesCommandScrollKeepsItWhereTheStripFits() async throws {
        let arbiter = FakeArbiter(answer: true)
        let h = Harness(model: Self.oneColumn(), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "a")
        let point = try h.center("a")
        _ = Base.scroll(h.root, from: page, at: point, dy: -20, phase: .began, command: true)
        await h.answered()
        #expect(!h.root.ownsCurrentScrollGesture, "the page owns it")
        #expect(!Base.scroll(h.root, from: page, at: point, dy: -20, phase: .changed, command: true))
        #expect(!Base.scroll(h.root, from: page, at: point, phase: .ended, command: true))
    }

    // MARK: web pages first

    /// Figma or Excalidraw under the pointer: the page cancels Command + wheel, so the held events
    /// go to its window in order, the rest of the gesture passes, and the columns stay.
    @Test func aPageThatHandlesCommandScrollKeepsTheGesture() async throws {
        let arbiter = FakeArbiter(answer: true)
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        let before = try #require(h.root.frame(of: "p2"))
        #expect(Base.scroll(h.root, from: page, at: point, phase: .mayBegin, command: true), "held while the page is asked")
        #expect(Base.scroll(h.root, from: page, at: point, dx: -20, phase: .began, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -20, phase: .changed, command: true))
        #expect(page.received.isEmpty, "nothing reaches the page before it answers")
        await h.answered()
        #expect(arbiter.asks.count == 1, "one ask per gesture")
        #expect(page.received.map(\.scrollingDeltaX) == [0, -20, -20], "the held events, in order")
        #expect(!h.root.ownsCurrentScrollGesture, "the page owns it now")
        #expect(!Base.scroll(h.root, from: page, at: point, dx: -20, phase: .changed, command: true), "the rest goes on")
        #expect(!Base.scroll(h.root, from: page, at: point, phase: .ended, command: true))
        #expect(!Base.scroll(h.root, from: page, at: point, dx: -10, momentum: .begin, command: true))
        h.settle()
        #expect(h.root.frame(of: "p2") == before, "the columns did not move")
    }

    /// An ordinary page: it does not cancel Command + wheel, so the columns pan with every held
    /// event and the rest of the gesture; the page sees none of it.
    @Test func aPageThatDoesNotHandleCommandScrollLetsTheColumnsPan() async throws {
        let arbiter = FakeArbiter(answer: false)
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        let before = try #require(h.root.frame(of: "p2"))
        #expect(Base.scroll(h.root, from: page, at: point, phase: .mayBegin, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -30, phase: .began, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -30, phase: .changed, command: true))
        await h.answered()
        #expect(arbiter.asks.count == 1)
        let strip = try #require(h.root.screenViews["s"])
        #expect(strip.isUserScrolling, "the held events started the pan")
        #expect(h.root.ownsCurrentScrollGesture)
        #expect(Base.scroll(h.root, from: page, at: point, dx: -30, phase: .changed, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, phase: .ended, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -10, momentum: .begin, command: true), "and its coast")
        #expect(Base.scroll(h.root, from: page, at: point, momentum: .end, command: true))
        #expect(page.received.isEmpty)
        h.settle()
        #expect(try #require(h.root.frame(of: "p2")).minX < before.minX - 30, "the columns panned")
    }

    /// A gesture shorter than the ask (a quick flick, ended before the answer) still pans.
    @Test func aFlickThatEndsBeforeThePageAnswersStillPans() async throws {
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: FakeArbiter(answer: false))
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        let before = try #require(h.root.frame(of: "p2"))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -40, phase: .began, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -40, phase: .changed, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -40, phase: .changed, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, phase: .ended, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -20, momentum: .begin, command: true))
        await h.answered()
        #expect(Base.scroll(h.root, from: page, at: point, momentum: .end, command: true), "the coast stays the layout's")
        #expect(!h.root.ownsCurrentScrollGesture)
        h.settle()
        #expect(try #require(h.root.frame(of: "p2")).minX < before.minX - 30)
    }

    /// A page that never answers (a stuck renderer) holds the gesture only until the deadline;
    /// its late answer changes nothing.
    @Test func aPageThatDoesNotAnswerInTimeLosesTheGestureToTheColumns() async throws {
        let arbiter = FakeArbiter(answer: true, waits: true)
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        #expect(Base.scroll(h.root, from: page, at: point, dx: -30, phase: .began, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -30, phase: .changed, command: true))
        let strip = try #require(h.root.screenViews["s"])
        #expect(!strip.isUserScrolling, "held while the page is asked")
        try await h.clock.waitForSleeper()
        h.clock.advance(by: h.root.pageProbeDeadline)
        for _ in 0..<100 where !strip.isUserScrolling { await Task.yield() }
        #expect(strip.isUserScrolling, "the deadline gave the gesture to the columns")
        arbiter.release()
        await h.root.pageProbeTask?.value
        #expect(page.received.isEmpty, "the late answer sends nothing")
        #expect(strip.isUserScrolling)
        #expect(Base.scroll(h.root, from: page, at: point, phase: .ended, command: true))
    }

    /// A Command wheel notch over a page that zooms with it goes to the page; the notches right
    /// after it in the same spin reuse the answer and pass at once.
    @Test func aCommandWheelOverAPageThatHandlesItGoesToThePage() async throws {
        let arbiter = FakeArbiter(answer: true)
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        #expect(Base.scroll(h.root, from: page, at: point, dy: -1, units: .line, command: true), "held")
        await h.answered()
        #expect(page.received.count == 1)
        #expect(!Base.scroll(h.root, from: page, at: point, dy: -1, units: .line, command: true), "the spin's next notch passes")
        #expect(arbiter.asks.count == 1)
    }

    @Test func aCommandWheelOverAnOrdinaryPagePansTheColumns() async throws {
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: FakeArbiter(answer: false))
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        let before = try #require(h.root.frame(of: "p2"))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -1, units: .line, command: true))
        await h.answered()
        #expect(page.received.isEmpty)
        h.settle()
        #expect(try #require(h.root.frame(of: "p2")).minX < before.minX - 30, "one notch, one column")
    }

    /// A plain scroll over a page is the page's: it is never held and the page is never asked.
    @Test func aPlainScrollOverAPageIsNeverHeld() throws {
        let arbiter = FakeArbiter(answer: false)
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        #expect(!Base.scroll(h.root, from: page, at: point, dx: -20, phase: .began))
        #expect(!Base.scroll(h.root, from: page, at: point, dy: -1, units: .line))
        #expect(arbiter.asks.isEmpty)
    }

    /// `layout.pagesHandleCommandScroll` off: the layout takes a Command scroll over a page at once
    /// and never asks it.
    @Test func withPagesFirstOffTheLayoutTakesCommandScrollOverAPageAtOnce() throws {
        let arbiter = FakeArbiter(answer: true)
        let model = Base.columnsModel(modifier: .command)
        model.pagesHandleCommandScrollOverride = false
        let h = Harness(model: model, arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        #expect(Base.scroll(h.root, from: page, at: point, dx: -20, phase: .began, command: true))
        #expect(Base.scroll(h.root, from: page, at: point, dx: -20, phase: .changed, command: true))
        #expect(try #require(h.root.screenViews["s"]).isUserScrolling)
        #expect(arbiter.asks.isEmpty)
        #expect(page.received.isEmpty)
    }

    /// While a page is asked, a scroll over a terminal (the layout's own window) is routed at once,
    /// never held for the page or sent to it.
    @Test func aScrollElsewhereDuringTheAskIsNotHeldForThePage() async throws {
        let arbiter = FakeArbiter(answer: true, waits: true)
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        #expect(Base.scroll(h.root, from: page, at: try h.center("p2"), dy: -1, units: .line, command: true), "held")
        #expect(!Base.scroll(h.root, at: try h.center("p3"), dy: -1, units: .line), "a plain notch over a terminal goes on now")
        arbiter.release()
        await h.answered()
        #expect(page.received.count == 1, "only the page's own notch reached it")
    }

    /// A wheel ask the deadline decided is not kept for the spin: the next notch asks again.
    @Test func aTimedOutWheelAskIsNotKeptForTheSpin() async throws {
        let arbiter = FakeArbiter(answer: true, waits: true)
        let h = Harness(model: Base.columnsModel(modifier: .command), arbiter: arbiter)
        defer { h.close() }
        let page = try h.page(over: "p2")
        let point = try h.center("p2")
        #expect(Base.scroll(h.root, from: page, at: point, dy: -1, units: .line, command: true))
        try await h.clock.waitForSleeper()
        h.clock.advance(by: h.root.pageProbeDeadline)
        for _ in 0..<100 where h.root.pageProbe != nil { await Task.yield() }
        #expect(h.root.pageProbe == nil, "the deadline let the columns take it")
        #expect(Base.scroll(h.root, from: page, at: point, dy: -1, units: .line, command: true), "held again")
        arbiter.release()
        await h.answered()
        #expect(arbiter.asks.count == 2, "asked again")
    }
}
