import AppKit
import QuartzCore

/// Drives spring animations from the view's display link (up to 120 Hz on
/// ProMotion). Pauses itself whenever `onFrame` reports nothing is moving.
final class DisplayLinkDriver: NSObject {
    /// Called once per frame with the elapsed seconds. Return true to keep ticking.
    var onFrame: ((Double) -> Bool)?

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    var isAttached: Bool { link != nil }
    /// The link is ticking (an animation is in flight).
    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    func attach(to view: NSView) {
        detach()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Breaks the link -> target retain cycle; call when leaving the window.
    func detach() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    func start() {
        guard let link, link.isPaused else { return }
        lastTimestamp = nil
        link.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp.map { now - $0 } ?? link.duration
        lastTimestamp = now
        let keepGoing = onFrame?(min(max(dt, 1.0 / 240.0), 1.0 / 30.0)) ?? false
        if !keepGoing { link.isPaused = true }
    }
}
