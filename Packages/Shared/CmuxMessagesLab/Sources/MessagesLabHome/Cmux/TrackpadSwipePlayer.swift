import AppKit

/// Automation (DEBUG socket): a two-finger trackpad swipe played in real time as a trackpad sends
/// it: fingers down (may-begin), began, one change per display frame, an optional still hold, then
/// lifted (ended). Each event goes through `NSApp.sendEvent`, so the app's local event monitors
/// (``SwipeReply``) see it before the window and its views, as they see a person's gesture. For
/// captures of gestures on a Mac with no trackpad at hand (`debugTreeDrive("swipe")`).
///
/// Paced by the view's display link (one step per frame), never by sleeps; the link holds the
/// player until the gesture ends.
@MainActor final class TrackpadSwipePlayer: NSObject {
    private let dx: CGFloat, dy: CGFloat
    private let duration: TimeInterval, hold: TimeInterval
    private let point: CGPoint
    private weak var window: NSWindow?
    private var start: CFTimeInterval?
    private var sent: CGPoint = .zero
    private var began = false
    private var link: CADisplayLink?

    /// `point`: window coordinates (from the bottom left); `dx`, `dy`: points over `duration` s
    /// (right and down positive), then `hold` s still before the fingers lift.
    init(point: CGPoint, dx: CGFloat, dy: CGFloat, duration: TimeInterval, hold: TimeInterval, window: NSWindow) {
        (self.point, self.dx, self.dy, self.duration, self.hold, self.window) = (point, dx, dy, max(duration, 0.01), max(hold, 0), window)
    }

    /// The gesture's whole length (s).
    var length: TimeInterval { duration + hold }

    /// Starts on `view`'s display link; returns at once.
    func play(on view: NSView) {
        post(phase: 128)
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        guard let start else { self.start = now; return }
        let t = now - start
        let f = CGFloat(min(1, t / duration))
        let want = CGPoint(x: dx * f, y: dy * f)
        if want != sent || !began {
            post(dx: want.x - sent.x, dy: want.y - sent.y, phase: began ? 2 : 1)
            began = true
            sent = want
        }
        guard t >= duration + hold else { return }
        post(phase: 4)
        link.invalidate()
        self.link = nil
    }

    private func post(dx: CGFloat = 0, dy: CGFloat = 0, phase: Int64) {
        guard let window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: CrashGuard.int(dy)), wheel2: Int32(clamping: CrashGuard.int(dx)), wheel3: 0) else { return }
        let screen = window.convertPoint(toScreen: point)
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        guard let e = NSEvent(cgEvent: event) else { return }
        NSApp.sendEvent(e)
    }
}
