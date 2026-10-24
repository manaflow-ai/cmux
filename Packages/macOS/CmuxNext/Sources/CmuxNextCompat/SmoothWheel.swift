import AppKit

/// Chrome-style smooth scrolling for a mouse wheel in a `WKWebView`.
///
/// WebKit scrolls a discrete wheel notch (no phase, no momentum,
/// `hasPreciseScrollingDeltas == false`) by one jump of line steps; Chrome
/// animates it. WebKit's own "Scroll animator" feature does not change that for
/// wheel events (measured on macOS 27: one 120 px jump either way), so a web
/// view hands each such notch to ``SmoothWheel/handle(_:in:)``. That keeps the
/// notch's distance, spreads it over 150 ms with a cubic ease-out
/// (notches add up and restart the ease, as in Chrome) and feeds the steps back to WebKit as
/// continuous, phase-less wheel events. WebKit then does everything else it
/// does for a pixel scroll: wheel listeners and `preventDefault`, nested
/// scrollers, scroll snap. No phases are sent, so there is no rubber band or
/// scroll latching, as with a real mouse.
///
/// Left alone: trackpad and any phased or momentum event, Shift/Control/
/// Option/Command wheel (horizontal, zoom, layout gestures), and a notch with
/// a horizontal part. Off when Reduce Motion is on or `browser.smoothWheelScroll`
/// is false (``isEnabled``).
@MainActor
public final class SmoothWheel {
    /// `browser.smoothWheelScroll` (default on). The App sets it from the settings snapshot.
    public static var isEnabled = true
    /// Tests drive frames themselves (``tick(seconds:)``): no display link starts.
    public static var manualTicks = false
    /// Test seam for Reduce Motion.
    public static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Distance of one line of a discrete notch: WebKit's own line step.
    public static let pixelsPerLine = 40.0

    private var curve = SmoothWheelCurve()
    private var location: CGPoint = .zero
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private let deliver: (NSEvent) -> Void
    /// Whether ``handle(_:in:)`` is delivering right now (its own events are not re-queued).
    private var delivering = false

    /// `deliver` passes an event to `WKWebView.scrollWheel(with:)` (super's).
    public init(deliver: @escaping (NSEvent) -> Void) {
        self.deliver = deliver
    }

    /// Whether `event` is a plain discrete vertical notch this class animates.
    public static func animates(_ event: NSEvent) -> Bool {
        guard isEnabled, !reduceMotion() else { return false }
        guard !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty else { return false }
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return false }
        return event.scrollingDeltaY != 0 && event.scrollingDeltaX == 0
    }

    /// Takes `event` when it is a discrete notch (true: the caller drops it).
    /// Any other event passes first the steps still owed, so order is kept.
    public func handle(_ event: NSEvent, in view: NSView) -> Bool {
        guard !delivering else { return false }
        guard Self.animates(event) else {
            flush()
            return false
        }
        self.view = view
        location = event.locationInWindow
        curve.add(distance: event.scrollingDeltaY * Self.pixelsPerLine)
        startLink(in: view)
        return true
    }

    /// Delivers what is still owed at once and stops (focus loss, a setting change, a passed-through event).
    public func flush() {
        guard !curve.isIdle else { return }
        let rest = curve.finish()
        stopLink()
        send(rest)
    }

    /// One frame. `seconds` is the time since the last one.
    public func tick(seconds: Double) {
        let step = curve.advance(seconds: seconds)
        if curve.isIdle { stopLink() }
        send(step)
    }

    private func send(_ pixels: Int) {
        guard pixels != 0, let event = Self.event(pixels: pixels, at: location) else { return }
        delivering = true
        deliver(event)
        delivering = false
    }

    /// A continuous, phase-less wheel event of `pixels` (negative scrolls down) at `location`
    /// in window coordinates. A window-less event reports its screen location as the
    /// window one, so the location is set to what AppKit turns back into `location`.
    static func event(pixels: Int, at location: CGPoint) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(pixels), wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(pixels))
        // Cocoa's screen space is bottom-left; CGEvent's global space is top-left of the primary display.
        let height = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: location.x, y: height - location.y)
        return NSEvent(cgEvent: cg)
    }

    private func startLink(in view: NSView) {
        guard link == nil, !Self.manualTicks else { return }
        lastTick = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = max(0.001, min(0.05, now - lastTick))
        lastTick = now
        tick(seconds: dt)
    }
}

/// The distance a wheel animation still owes, and how fast it pays it:
/// Chrome's per-notch ease-out. The distance left (all notches so far) is
/// paid over ``duration`` on a cubic ease-out, `1 - (1 - t)^3`; a notch that
/// arrives mid-animation adds to what is left and restarts the curve, which is
/// what makes a fast series of notches speed up. Whole pixels only; the
/// fraction carries to the next frame.
public struct SmoothWheelCurve: Sendable {
    /// Chrome's wheel animation length.
    public static let duration = 0.15
    /// What the current ease still owes, and how much of it is paid.
    private var total = 0.0
    private var paid = 0.0
    private var elapsed = 0.0
    private var carried = 0.0
    public init() {}

    public var isIdle: Bool { total == 0 && carried == 0 }

    public mutating func add(distance: Double) {
        total = (total - paid) + distance
        paid = 0
        elapsed = 0
    }

    /// Pixels to scroll this frame (sign as the distance added).
    public mutating func advance(seconds: Double) -> Int {
        guard total != 0 else { return 0 }
        elapsed = min(Self.duration, elapsed + seconds)
        let t = elapsed / Self.duration
        let position = total * (1 - pow(1 - t, 3))
        let want = position - paid + carried
        let whole = want.rounded(.towardZero)
        carried = want - whole
        paid = position
        if t >= 1 {
            let last = Int(whole) + Int(carried.rounded())
            total = 0; paid = 0; carried = 0; elapsed = 0
            return last
        }
        return Int(whole)
    }

    /// All that is left, at once.
    public mutating func finish() -> Int {
        defer { total = 0; paid = 0; carried = 0; elapsed = 0 }
        return Int(((total - paid) + carried).rounded())
    }
}
