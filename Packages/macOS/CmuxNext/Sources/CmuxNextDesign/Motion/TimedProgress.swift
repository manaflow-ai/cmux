public import AppKit
import CCmuxMotionFFI

/// A timed transition (a duration on a curve) stepped by the window's ``MotionClock``, the clock every spring of the
/// window steps on: the panes, the dividers, the tab strip. A timed animation of AppKit (`NSAnimationContext` and a
/// constraint's `animator()`) runs on a timer of its own, so its frames and the springs' frames land in different
/// passes and drift apart; on the clock they step in the same frame with the same `dt` and show in one commit (Leo
/// 2026-11-05: "If we had a proper animation system, everything moves as one, as one").
///
/// `apply` gets the progress, 0 at the start and 1 at the end, on every frame; the owner maps it onto what it moves
/// (several values on one progress move as one). A new `run` starts from wherever the last one shows, so a toggle
/// mid-flight turns around from the frame on screen. With no animation (`duration` 0: Reduce Motion, the category off)
/// the end applies in the same turn and the completion runs at once.
@MainActor
public final class TimedProgress: MotionAnimating {
    /// The curve: `Motion.fadeCurve`'s ease-out, CSS `cubic-bezier(0, 0, 0.58, 1)`.
    static let curve = (x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)

    private let apply: @MainActor (Double) -> Void
    private var elapsed: Double = 0
    private var duration: Double = 0
    private var completion: (@MainActor () -> Void)?
    private weak var clock: MotionClock?
    /// Whether a transition is under way (started and not at its end).
    public private(set) var isRunning = false

    public init(apply: @escaping @MainActor (Double) -> Void) {
        self.apply = apply
    }

    /// Runs a transition of `duration` seconds on `view`'s window clock. `completion` runs after the last frame's
    /// `apply`; a transition replaced by a newer `run` or ended by `stop` never runs its completion.
    public func run(duration: TimeInterval, in view: NSView, trace: String, completion: (@MainActor () -> Void)? = nil) {
        stop()
        guard duration > 0 else {
            apply(1)
            completion?()
            return
        }
        (elapsed, self.duration, self.completion, isRunning) = (0, duration, completion, true)
        let clock = MotionClock.forView(view)
        self.clock = clock
        clock.run(self, trace: trace)
    }

    /// Ends the transition where it shows, with no further `apply` and no completion.
    public func stop() {
        guard isRunning else { return }
        (isRunning, completion) = (false, nil)
        clock?.stop(self)
    }

    /// The curve's progress at `fraction` (0...1) of the duration.
    public static func progress(at fraction: Double) -> Double {
        let t = min(max(fraction, 0), 1)
        return t >= 1 ? 1 : cmux_motion_cubic_bezier(curve.x1, curve.y1, curve.x2, curve.y2, t)
    }

    public func motionStep(_ dt: Double) -> Bool { // perf-hot: 4ms motion-frame
        guard isRunning else { return false }
        elapsed += dt
        let fraction = elapsed / duration
        apply(Self.progress(at: fraction))
        guard fraction >= 1 else { return true }
        let done = completion
        (isRunning, completion) = (false, nil)
        done?()
        return false
    }

    public func motionSettle() {
        guard isRunning else { return }
        elapsed = duration
        _ = motionStep(0)
    }
}
