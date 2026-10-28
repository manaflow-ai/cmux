import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Steps the layout's springs (panes, dividers, columns, screens, drop
/// zones) on the window's one `MotionClock`, the clock the tab strip and the
/// sidebar rows also step on (up to 120 Hz on ProMotion). Goes idle whenever
/// `onFrame` reports nothing is moving, so the window's display link stops
/// with the last animation.
final class DisplayLinkDriver: MotionAnimating {
    /// Called once per frame with the elapsed seconds. Return true to keep ticking.
    var onFrame: ((Double) -> Bool)?
    /// Tests are the clock: `start` asks for no display-link frames, and the test steps
    /// `LayoutRootView.advanceFrame` at a fixed dt instead.
    var isManual = false
    /// Every `start` call, manual or not: the display frames the layout asked for (tests).
    private(set) var startRequests = 0
    /// The display-link time of the frame `onFrame` steps (`FrameTick.timestamp`); nil outside a
    /// display-link step (a test steps `advanceFrame` by hand).
    private(set) var frameTime: CFTimeInterval?

    private weak var view: NSView?
    private weak var clock: MotionClock?

    var isAttached: Bool { view != nil }
    /// An animation is in flight.
    var isRunning: Bool { clock?.isRunning(self) ?? false }

    func attach(to view: NSView) {
        detach()
        self.view = view
    }

    /// Stops ticking; call when leaving the window.
    func detach() {
        clock?.stop(self)
        clock = nil
        view = nil
    }

    func start() {
        startRequests &+= 1
        guard let view, !isManual else { return }
        let target = MotionClock.forView(view)
        if let clock, clock !== target { clock.stop(self) }
        clock = target
        target.run(self, trace: "layout")
    }

    func motionStep(_ tick: FrameTick) -> Bool {
        frameTime = tick.timestamp
        defer { frameTime = nil }
        return onFrame?(tick.elapsed) ?? false
    }
}
