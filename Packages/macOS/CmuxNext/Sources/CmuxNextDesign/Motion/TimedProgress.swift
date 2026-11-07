public import AppKit
import CCmuxMotionFFI
public import CmuxNextDesignTokens

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
    /// The default curve: `Motion.fadeCurve`'s ease-out, CSS `cubic-bezier(0, 0, 0.58, 1)`.
    static let curve = (x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)

    private let apply: @MainActor (Double) -> Void
    private var elapsed: Double = 0
    private var duration: Double = 0
    /// The running transition's curve (``curve`` unless it runs a ``MotionCurve``).
    private var points = TimedProgress.curve
    private var completion: (@MainActor () -> Void)?
    /// The end is applied and waits a frame for its completion: the frame that applied it is committed first.
    private var landed = false
    private weak var clock: MotionClock?
    /// Whether a transition is under way (started and not at its end).
    public private(set) var isRunning = false

    public init(apply: @escaping @MainActor (Double) -> Void) {
        self.apply = apply
    }

    /// Runs a transition of `duration` seconds on `view`'s window clock. `completion` runs on the frame after the one
    /// that applied the end, once that frame is committed (as an AppKit animation's completion runs once its last
    /// frame shows), so whoever reads the transition as settled reads the end on screen; a transition replaced by a
    /// newer `run` or ended by `stop` never runs its completion.
    public func run(duration: TimeInterval, in view: NSView, trace: String, completion: (@MainActor () -> Void)? = nil) {
        start(duration: duration, points: Self.curve, in: view, trace: trace, completion: completion)
    }

    /// Runs a transition of `duration` seconds on `curve` (a gate's ``MotionGate/run(_:curve:in:trace:completion:)``
    /// gives the duration), as ``run(duration:in:trace:completion:)``.
    public func run(duration: TimeInterval, curve: MotionCurve, in view: NSView, trace: String,
                    completion: (@MainActor () -> Void)? = nil) {
        start(duration: duration, points: Self.points(curve), in: view, trace: trace, completion: completion)
    }

    private func start(duration: TimeInterval, points: (x1: Double, y1: Double, x2: Double, y2: Double), in view: NSView,
                       trace: String, completion: (@MainActor () -> Void)?) {
        stop()
        guard duration > 0 else {
            apply(1)
            completion?()
            return
        }
        (elapsed, self.duration, self.points, self.completion, isRunning, landed) = (0, duration, points, completion, true, false)
        let clock = MotionClock.forView(view)
        self.clock = clock
        clock.run(self, trace: trace)
    }

    /// Ends the transition where it shows, with no further `apply` and no completion.
    public func stop() {
        guard isRunning else { return }
        (isRunning, completion, landed) = (false, nil, false)
        clock?.stop(self)
    }

    /// The default curve's progress at `fraction` (0...1) of the duration.
    public static func progress(at fraction: Double) -> Double { progress(at: fraction, on: curve) }

    /// `curve`'s progress at `fraction` (0...1) of its duration.
    public static func progress(at fraction: Double, curve: MotionCurve) -> Double {
        progress(at: fraction, on: points(curve))
    }

    private static func progress(at fraction: Double, on points: (x1: Double, y1: Double, x2: Double, y2: Double)) -> Double {
        let t = min(max(fraction, 0), 1)
        return t >= 1 ? 1 : cmux_motion_cubic_bezier(points.x1, points.y1, points.x2, points.y2, t)
    }

    private static func points(_ curve: MotionCurve) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let (x1, y1, x2, y2) = curve.controlPoints
        return (Double(x1), Double(y1), Double(x2), Double(y2))
    }

    public func motionStep(_ dt: Double) -> Bool { // perf-hot: 4ms motion-frame
        guard isRunning else { return false }
        guard !landed else { return finish() }
        elapsed += dt
        let fraction = elapsed / duration
        apply(Self.progress(at: fraction, on: points))
        // The end shows in this frame's commit; the completion waits for the next frame.
        if fraction >= 1 { landed = true }
        return true
    }

    public func motionSettle() {
        guard isRunning else { return }
        if !landed { apply(1) }
        _ = finish()
    }

    private func finish() -> Bool {
        let done = completion
        (isRunning, completion, landed) = (false, nil, false)
        done?()
        return false
    }
}

extension MotionGate {
    /// Runs `progress` over `curve` on `view`'s window clock (``TimedProgress``), every value it moves in the same
    /// frame: its duration is this category's (``duration(curve:)``), so with movement off (the master switch, the
    /// category, speed "off", Reduce Motion) or a view that cannot animate (``Motion/canAnimate(in:)``) the end applies
    /// now and `completion` runs now. A run under way turns around from the frame on screen.
    public func run(_ progress: TimedProgress, curve: MotionCurve, in view: NSView, trace: String,
                    completion: (@MainActor () -> Void)? = nil) {
        let duration = canAnimate(in: view) ? self.duration(curve: curve) : 0
        progress.run(duration: duration, curve: curve, in: view, trace: trace, completion: completion)
    }
}
