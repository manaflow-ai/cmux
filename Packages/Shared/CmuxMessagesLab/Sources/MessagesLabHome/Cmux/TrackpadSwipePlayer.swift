import AppKit

/// Automation (DEBUG socket): a two-finger trackpad swipe played in real time as a trackpad sends
/// it: fingers down (may-begin), began, one change per display frame, an optional still hold, then
/// lifted (ended). `deliver` takes each event: `debugTreeDrive("swipe")` sends one the window server
/// placed in the window through `NSApp.sendEvent` (local monitors, then the window), and one it did
/// not (an app that is not frontmost gets no window for a made-up event) through the swipe's monitor
/// path and then the transcript's scroll view, as that dispatch would (``MessagesLabHomeView/debugSwipePlayer(_:)``).
/// For captures of gestures on a Mac with no trackpad at hand.
///
/// Paced by the view's display link (one step per frame), never by sleeps; the link holds the
/// player until the gesture ends.
@MainActor final class TrackpadSwipePlayer: NSObject {
    private let dx: CGFloat, dy: CGFloat
    private let duration: TimeInterval, hold: TimeInterval
    /// Where the fingers are, in window coordinates.
    let point: CGPoint
    private weak var window: NSWindow?
    private let deliver: (NSEvent) -> String
    /// How the first event went (`app` or `monitor`), for the answer.
    private(set) var route = ""
    private var start: CFTimeInterval?
    /// Whole points sent so far: AppKit reads a made-up event's point deltas as integers (cut toward
    /// zero), so each event carries the rounded path's next step and the steps add up to the path
    /// (a 100 x 90 diagonal at 120 Hz cut to (2, -1) steps read as twice as horizontal).
    private var sent = (x: 0, y: 0)
    private var began = false
    private var lifted = false
    /// The fingers-down time (ns since startup); each event is stamped `t` s after it.
    private var base: UInt64 = 0
    private var link: CADisplayLink?

    /// `point`: window coordinates (from the bottom left); `dx`, `dy`: points over `duration` s
    /// (right and down positive), then `hold` s still before the fingers lift.
    /// `deliver` dispatches one event and names its route.
    init(point: CGPoint, dx: CGFloat, dy: CGFloat, duration: TimeInterval, hold: TimeInterval, window: NSWindow,
         deliver: @escaping (NSEvent) -> String) {
        (self.point, self.dx, self.dy, self.duration, self.hold, self.window) = (point, dx, dy, max(duration, 0.01), max(hold, 0), window)
        self.deliver = deliver
    }

    /// The gesture's whole length (s).
    var length: TimeInterval { duration + hold }

    /// Starts on `view`'s display link; returns at once.
    func play(on view: NSView) {
        begin()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Fingers down (may-begin); `advance(to:)` plays the rest.
    func begin() {
        base = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        post(phase: 128, at: 0)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        guard let start else { self.start = now; return }
        if advance(to: now - start) {
            link.invalidate()
            self.link = nil
        }
    }

    /// One frame `t` s into the gesture: the change since the last frame (none while still), then
    /// the release once the hold is over. True when the fingers have lifted.
    ///
    /// The state moves on before each event goes out: a view that runs a run loop inside its
    /// handler (a scroll view's gesture tracking) lets the display link call this again, and that
    /// call must see the event as sent, not send the start of the gesture a second time.
    @discardableResult
    func advance(to t: TimeInterval) -> Bool {
        guard !lifted else { return true }
        let f = CGFloat(min(1, t / duration))
        let want = (x: CrashGuard.int(dx * f), y: CrashGuard.int(dy * f))
        if want != sent || !began {
            let (step, phase) = ((x: want.x - sent.x, y: want.y - sent.y), began ? 2 : 1 as Int64)
            (began, sent) = (true, want)
            post(dx: step.x, dy: step.y, phase: phase, at: t)
        }
        guard t >= duration + hold else { return false }
        lifted = true
        post(phase: 4, at: t)
        return true
    }

    private func post(dx: Int = 0, dy: Int = 0, phase: Int64, at t: TimeInterval) {
        guard let window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) else { return }
        let screen = window.convertPoint(toScreen: point)
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        event.timestamp = base &+ UInt64(clamping: CrashGuard.int(max(0, t) * 1e9, in: 0...Int.max))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(truncatingIfNeeded: window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(truncatingIfNeeded: window.windowNumber))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(clamping: dy))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(clamping: dx))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        guard let e = NSEvent(cgEvent: event) else { return }
        let how = deliver(e)
        if route.isEmpty { route = how }
    }
}
