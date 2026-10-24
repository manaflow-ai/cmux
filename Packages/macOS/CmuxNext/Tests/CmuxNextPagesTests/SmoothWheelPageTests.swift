import AppKit
import CmuxNextCompat
import Testing
import WebKit
@testable import CmuxNextPages

/// A mouse-wheel notch scrolls a page over several positions, like Chrome; a trackpad
/// (continuous) event reaches WebKit untouched (user 2026-10-24).
@MainActor
@Suite(.serialized)
struct SmoothWheelPageTests {
    final class Fixture: NSObject, WKNavigationDelegate {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        private var loaded: CheckedContinuation<Void, Never>?

        func load() async {
            window.contentView = web
            web.navigationDelegate = self
            await withCheckedContinuation { loaded = $0
                web.loadHTMLString("<body style='margin:0'><div style='height:20000px'></div></body>", baseURL: nil)
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }

        func y() async -> Double {
            (try? await web.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        }

        /// A discrete notch of `lines` (negative scrolls down), as a mouse wheel sends it.
        func notch(lines: Int32, flags: CGEventFlags = []) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            cg.flags = flags
            cg.location = CGPoint(x: 200, y: NSScreen.screens[0].frame.height - 200)
            return NSEvent(cgEvent: cg)!
        }

        /// A trackpad-style event: continuous pixel deltas.
        func trackpad(pixels: Int32) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(pixels))
            cg.location = CGPoint(x: 200, y: NSScreen.screens[0].frame.height - 200)
            return NSEvent(cgEvent: cg)!
        }

        /// Frames of 1/60 s until the animation is paid, sampling the scroll position after each.
        func runFrames(_ count: Int) async -> [Double] {
            var seen: [Double] = []
            for _ in 0..<count {
                web.smoothWheel.tick(seconds: 1.0 / 60)
                try? await Task.sleep(for: .milliseconds(40))
                seen.append(await y())
            }
            return seen
        }
    }

    private func distinct(_ values: [Double]) -> [Double] {
        var out: [Double] = []
        for v in values where v != out.last { out.append(v) }
        return out
    }

    @Test func discreteNotchScrollsThroughIntermediatePositions() async {
        SmoothWheel.manualTicks = true
        SmoothWheel.isEnabled = true
        SmoothWheel.reduceMotion = { false }
        let f = Fixture()
        await f.load()
        let event = f.notch(lines: -3)
        #expect(!event.hasPreciseScrollingDeltas)
        f.web.scrollWheel(with: event)
        // The event is held back: nothing has moved before the first frame.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await f.y() == 0)
        let positions = distinct(await f.runFrames(24))
        #expect(positions.count >= 6, "scroll positions \(positions)")
        #expect(positions.last == (abs(event.scrollingDeltaY) * SmoothWheel.pixelsPerLine).rounded())
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func trackpadEventPassesStraightThrough() async {
        SmoothWheel.manualTicks = true
        SmoothWheel.isEnabled = true
        SmoothWheel.reduceMotion = { false }
        let f = Fixture()
        await f.load()
        f.web.scrollWheel(with: f.trackpad(pixels: -90))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await f.y() == 90)
    }

    @Test func shiftWheelAndSettingOffAndReduceMotionPassThrough() async {
        SmoothWheel.manualTicks = true
        SmoothWheel.reduceMotion = { false }
        let f = Fixture()
        await f.load()
        SmoothWheel.isEnabled = true
        #expect(!SmoothWheel.animates(f.notch(lines: -3, flags: .maskShift)))
        #expect(!SmoothWheel.animates(f.notch(lines: -3, flags: .maskCommand)))
        #expect(!SmoothWheel.animates(f.notch(lines: -3, flags: .maskControl)))
        #expect(SmoothWheel.animates(f.notch(lines: -3)))
        SmoothWheel.isEnabled = false
        #expect(!SmoothWheel.animates(f.notch(lines: -3)))
        SmoothWheel.isEnabled = true
        SmoothWheel.reduceMotion = { true }
        #expect(!SmoothWheel.animates(f.notch(lines: -3)))
        SmoothWheel.reduceMotion = { false }
    }
}
