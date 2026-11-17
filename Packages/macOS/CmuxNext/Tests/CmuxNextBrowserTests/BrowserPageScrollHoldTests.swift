@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// Holding `j` or `k` in a page (user, 2026-11-17: "in browser holding j/k to scroll doesn't
/// feel intuitive"). Each key-down used to run one instant 60px `scrollBy`, so a held key sat
/// still for the system's key-repeat delay, then jumped 60px per repeat. The page's frame
/// clock now drives the scroll: a held key moves at a constant speed from the first frame,
/// through the repeat delay, and stops within a few frames of key-up; a tap still moves one
/// 60px step; Reduce Motion keeps the instant steps.
///
/// The real script runs in JavaScriptCore against a small page: one scroller, a frame clock the
/// test advances (60 Hz), and the window's key events.
struct BrowserPageScrollHoldTests {
    static let frame = 1000.0 / 60

    /// A page with a long document, a frame clock and window events.
    final class Page {
        let context = JSContext()!
        private(set) var now = 0.0

        init(reduceMotion: Bool = false) {
            context.exceptionHandler = { _, exception in Issue.record("page threw: \(exception?.toString() ?? "?")") }
            context.evaluateScript("""
            var __now = 0, __rafs = new Map(), __nextRaf = 1, __listeners = {};
            var performance = { now: () => __now };
            function requestAnimationFrame(cb) { const id = __nextRaf++; __rafs.set(id, cb); return id; }
            function cancelAnimationFrame(id) { __rafs.delete(id); }
            var innerWidth = 1200, innerHeight = 800;
            const __el = {
              scrollTop: 0, scrollHeight: 100000, clientHeight: 800, scrollCalls: 0,
              clamp(v) { return Math.max(0, Math.min(this.scrollHeight - this.clientHeight, v)); },
              scrollBy(o) { this.scrollCalls++; this.scrollTop = this.clamp(this.scrollTop + (o.top || 0)); },
              scrollTo(o) { this.scrollCalls++; this.scrollTop = this.clamp(o.top || 0); },
            };
            const __on = (t, f) => { (__listeners[t] = __listeners[t] || []).push(f); };
            const __off = (t, f) => { __listeners[t] = (__listeners[t] || []).filter((g) => g !== f); };
            var window = globalThis;
            window.addEventListener = __on; window.removeEventListener = __off;
            var document = {
              scrollingElement: __el, documentElement: __el, body: { getElementsByTagName: () => [] },
              activeElement: null, visibilityState: 'visible',
              addEventListener: __on, removeEventListener: __off,
            };
            function getComputedStyle() { return { overflowY: 'auto' }; }
            function matchMedia(q) { return { matches: \(reduceMotion) && q.includes('reduce') }; }
            function __tick(ms) {
              __now = ms;
              const due = [...__rafs.values()]; __rafs.clear();
              for (const cb of due) cb(ms);
            }
            function __dispatch(type, init) {
              for (const f of (__listeners[type] || []).slice()) f(Object.assign({ type, isTrusted: true, repeat: false }, init));
            }
            """)
        }

        var scrollTop: Double { context.evaluateScript("__el.scrollTop").toDouble() }
        var pendingFrames: Int { Int(context.evaluateScript("__rafs.size").toInt32()) }

        func run(_ script: String) { context.evaluateScript(script) }

        /// Advances the clock to `ms` and runs the frame callbacks due.
        func tick(to ms: Double) {
            now = ms
            context.evaluateScript("__tick(\(ms))")
        }

        func key(_ type: String, _ letter: String, repeat isRepeat: Bool = false) {
            context.evaluateScript("__dispatch('\(type)', { key: '\(letter)', code: 'Key\(letter.uppercased())', repeat: \(isRepeat) })")
        }

        /// Runs frames until `ms`, recording each frame's movement; `between` runs before each frame.
        func frames(until ms: Double, between: (Double) -> Void = { _ in }) -> [(at: Double, delta: Double)] {
            var out: [(Double, Double)] = []
            while now + BrowserPageScrollHoldTests.frame <= ms + 0.001 {
                let next = now + BrowserPageScrollHoldTests.frame
                between(next)
                let before = scrollTop
                tick(to: next)
                out.append((next, scrollTop - before))
            }
            return out
        }
    }

    /// The host's side of a held key: the key-down's report runs the action, and the system
    /// repeats the key-down after its repeat delay (500 ms here), every 33 ms, each a report.
    private static func holdJ(_ page: Page, until release: Double) -> [(at: Double, delta: Double)] {
        page.key("keydown", "j")
        page.run(BrowserPageScroll.down.script)
        var nextRepeat = 500.0
        return page.frames(until: release) { at in
            while nextRepeat <= at {
                page.key("keydown", "j", repeat: true)
                page.run(BrowserPageScroll.down.script)
                nextRepeat += 33
            }
        }
    }

    @Test func aHeldKeyScrollsEveryFrameFromTheFirstThroughTheRepeatDelay() {
        let page = Page()
        let frames = Self.holdJ(page, until: 1000)
        #expect(frames.first.map { $0.delta > 0 && $0.delta <= 12 } == true,
                "the first frame moves a frame's worth (~10px at 600px/s), not a 60px jump: \(frames.prefix(3))")
        #expect(frames.allSatisfy { $0.delta > 0 }, "no frame stands still (no pause at the key-repeat delay): \(frames.filter { $0.delta <= 0 })")
        let cruise = frames.filter { $0.at <= 200 }.map(\.delta)
        #expect(cruise.allSatisfy { abs($0 - 10) <= 1 }, "a constant 600px/s for the first 200 ms: \(cruise)")
        let fast = frames.filter { $0.at >= 520 }.map(\.delta)
        #expect(fast.allSatisfy { abs($0 - 20) <= 1 }, "then a constant 1200px/s; repeats add no jumps: \(fast)")
        let all = frames.map(\.delta)
        #expect(zip(all, all.dropFirst()).allSatisfy { $1 >= $0 - 1 }, "speed never drops while held: \(all)")
    }

    @Test func keyUpStopsWithinThreeFrames() {
        let page = Page()
        _ = Self.holdJ(page, until: 1000)
        let atRelease = page.scrollTop
        page.key("keyup", "j")
        let after = page.frames(until: 1200)
        let moving = after.filter { $0.delta != 0 }
        #expect(moving.count <= 3, "stops within 3 frames (~50 ms) of key-up: \(after)")
        #expect(page.scrollTop - atRelease <= 31, "a short decay, not a coast: \(page.scrollTop - atRelease)px")
        #expect(zip(moving, moving.dropFirst()).allSatisfy { $1.delta <= $0.delta }, "it slows down, it never speeds up: \(moving)")
        #expect(page.pendingFrames == 0, "no frame callback left once stopped")
    }

    @Test func aTapMovesOneStep() {
        let page = Page()
        page.key("keydown", "j")
        page.run(BrowserPageScroll.down.script)
        _ = page.frames(until: 85)
        page.key("keyup", "j")
        _ = page.frames(until: 400)
        #expect(page.scrollTop >= 60 && page.scrollTop <= 70, "a tap is one 60px step: \(page.scrollTop)")
        #expect(page.pendingFrames == 0)
    }

    @Test func kScrollsUpTheSameWay() {
        let page = Page()
        page.run("__el.scrollTop = 5000")
        page.key("keydown", "k")
        page.run(BrowserPageScroll.up.script)
        let frames = page.frames(until: 150)
        #expect(frames.allSatisfy { abs($0.delta + 10) <= 1 }, "600px/s up: \(frames)")
        page.key("keyup", "k")
        _ = page.frames(until: 400)
        #expect(page.pendingFrames == 0)
    }

    @Test func reduceMotionKeepsInstantSteps() {
        let page = Page(reduceMotion: true)
        page.key("keydown", "j")
        page.run(BrowserPageScroll.down.script)
        #expect(page.scrollTop == 60, "one instant 60px step")
        #expect(page.pendingFrames == 0, "no animation under Reduce Motion")
    }
}
