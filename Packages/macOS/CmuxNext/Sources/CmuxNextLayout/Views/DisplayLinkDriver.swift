import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Drives spring animations from the window's ``FrameScheduler`` (up to
/// 120 Hz on ProMotion). Goes idle whenever `onFrame` reports nothing is
/// moving, so the window's display link stops with the last animation.
final class DisplayLinkDriver {
    /// Called once per frame with the elapsed seconds. Return true to keep ticking.
    var onFrame: ((Double) -> Bool)?

    private var client: FrameClient?

    var isAttached: Bool { client != nil }
    /// An animation is in flight.
    var isRunning: Bool { client?.isActive ?? false }

    func attach(to view: NSView) {
        detach()
        client = FrameClient(owner: "Layout.animation", view: view) { [weak self] tick in
            let keepGoing = self?.onFrame?(tick.elapsed) ?? false
            if !keepGoing { MotionTrace.end("layout") }
            return keepGoing
        }
    }

    /// Stops ticking; call when leaving the window.
    func detach() {
        if client?.isActive == true { MotionTrace.end("layout") }
        client?.deactivate()
        client = nil
    }

    func start() {
        guard let client, !client.isActive else { return }
        MotionTrace.begin("layout")
        client.activate()
    }
}
