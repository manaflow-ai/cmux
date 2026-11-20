import AppKit
import CmuxNextDesign

/// Steps the layout's springs (panes, dividers, columns, screens, drop
/// zones) on the window's one `MotionClock`, the clock the tab strip and the
/// sidebar rows also step on (up to 120 Hz on ProMotion). Goes idle whenever
/// `onFrame` reports nothing is moving, so the window's display link stops
/// with the last animation.
final class DisplayLinkDriver: MotionAnimating {
    /// Called once per frame with the elapsed seconds. Return true to keep ticking.
    var onFrame: ((Double) -> Bool)?
    /// Lays the layout out at its final state in one pass (the window went out of sight).
    var onSettle: (() -> Void)?
    /// Tests are the clock: `start` asks for no display-link frames, and the test steps
    /// `LayoutRootView.advanceFrame` at a fixed dt instead.
    var isManual = false

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

    /// `start` calls, cumulative, manual ones too (`LayoutWorkProbe`: a still pointer asks for no frames).
    private(set) var startRequests = 0

    func start() {
        startRequests += 1
        guard let view, !isManual else { return }
        let target = MotionClock.forView(view)
        if let clock, clock !== target { clock.stop(self) }
        clock = target
        target.run(self, trace: "layout")
    }

    func motionStep(_ dt: Double) -> Bool {
        onFrame?(dt) ?? false
    }

    func motionSettle() {
        onSettle?()
    }
}
