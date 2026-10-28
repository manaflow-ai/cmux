public import AppKit
public import QuartzCore
public import CmuxNextDesignTokens
import CmuxNextCompat

/// A fade-in that waits for its content: new content (a split's new terminal, before its shell's first output) is
/// laid out at rest at once and its layers stay at opacity 0 until the content drew its first frame (``FadeInWait/contentDrawn()``), then fade in
/// (``MotionGate/fadeIn(_:layers:in:completion:)``). The wait has a ceiling: one Core Animation keyframe animation
/// per layer holds it at 0 for at most `wait` seconds and then runs the same fade by itself, so content that is slow
/// to draw still comes in, and no timer or frame callback runs on the main thread for it. Both phases are on the
/// render server; the layers' model opacity stays at rest the whole time, so hit tests, focus and layout read the
/// pane as there from the key's turn (Chrome: a new view's layer opacity animates in the compositor while the view
/// already has its bounds and takes input, ui/compositor/layer_animator.h).
extension MotionGate {
    /// Holds `layers`, shown in `view`, at opacity 0 for up to `wait` seconds, then fades them in over `token`'s
    /// duration; ``FadeInWait/contentDrawn()`` starts the fade earlier. Returns nil, and changes nothing, when the
    /// gate does not fade (the master switch, the category, speed off) or `view`'s display draws no frames: the
    /// content then shows in this frame. `ended` runs once, after this turn, with the wait it ends, when the hold is
    /// over: its own fade landed, or the content's fade replaced it (not after ``FadeInWait/cancel()``).
    public func fadeIn(_ token: MotionFade, layers: [CALayer], in view: NSView, waitingUpTo wait: TimeInterval,
                       ended: @escaping @MainActor (FadeInWait) -> Void = { _ in }) -> FadeInWait? {
        let seconds = canAnimate(in: view) ? duration(token) : 0
        guard seconds > 0, !layers.isEmpty else { return nil }
        let pending = FadeInWait(gate: self, token: token, layers: layers, view: view, holdSeconds: max(0, wait), ended: ended)
        pending.hold(fadeSeconds: seconds)
        return pending
    }

    /// ``fadeIn(_:layers:in:waitingUpTo:ended:)`` for content that reports its first frame through `whenDrawn` (which
    /// runs its callback once, at once when the content drew already, and returns what cancels the wait). The wait
    /// starts first: content that drew already is not held or faded, and nil comes back. Otherwise the layers are held
    /// until the report and the frame wait stops when the hold ends; ``FadeInWait/cancel()`` stops it too.
    public func fadeIn(_ token: MotionFade, layers: [CALayer], in view: NSView, waitingUpTo wait: TimeInterval,
                       whenDrawn: (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)?,
                       ended: @escaping @MainActor (FadeInWait) -> Void = { _ in }) -> FadeInWait? {
        final class Report {
            var drawn = false
            weak var wait: FadeInWait?
        }
        let report = Report()
        let cancelFrame = whenDrawn { [report] in
            if let wait = report.wait { wait.contentDrawn() } else { report.drawn = true }
        }
        guard !report.drawn, let pending = fadeIn(token, layers: layers, in: view, waitingUpTo: wait, ended: { pending in
            let stop = pending.stopWaiting
            pending.stopWaiting = {}
            stop()
            ended(pending)
        }) else {
            cancelFrame?()
            return nil
        }
        report.wait = pending
        pending.stopWaiting = cancelFrame ?? {}
        return pending
    }
}

/// A fade-in held until its content drew (``MotionGate/fadeIn(_:layers:in:waitingUpTo:ended:)``).
@MainActor
public final class FadeInWait {
    /// The key of the hold on each layer.
    static let holdKey = "cmux.fadeIn.hold"

    private let gate: MotionGate
    private let token: MotionFade
    private let layers: [CALayer]
    private weak var view: NSView?
    private let holdSeconds: TimeInterval
    private var ended: (@MainActor (FadeInWait) -> Void)?
    /// When the hold stops holding and its own fade starts (`CACurrentMediaTime`).
    private var holdEnds: CFTimeInterval = 0
    /// The fade started (by the content or by the hold's ceiling), or the wait was cancelled.
    public private(set) var isSettled = false
    /// Stops the content's first-frame wait (``MotionGate/fadeIn(_:layers:in:waitingUpTo:whenDrawn:ended:)``): run once,
    /// when the hold ends or is cancelled.
    var stopWaiting: @MainActor () -> Void = {}

    init(gate: MotionGate, token: MotionFade, layers: [CALayer], view: NSView, holdSeconds: TimeInterval,
         ended: @escaping @MainActor (FadeInWait) -> Void) {
        self.gate = gate
        self.token = token
        self.layers = layers
        self.view = view
        self.holdSeconds = holdSeconds
        self.ended = ended
    }

    /// Adds the hold: an additive opacity offset of minus each layer's rest opacity for `holdSeconds`, then back to
    /// 0 over `fadeSeconds` on the fade curve, in one transaction whose completion ends the wait.
    func hold(fadeSeconds: TimeInterval) {
        let total = holdSeconds + fadeSeconds
        let now = CACurrentMediaTime()
        holdEnds = now + holdSeconds
        // The whole hold counts as motion in flight (`MotionActivity`, the late-commit telemetry): its fade can start
        // at any point of it (the content's first frame), or at its end.
        MotionActivity.began(seconds: total)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Runs when every hold ended or was removed (the content's fade replaced it): the layers are at rest then
        // or on the replacing fade, and the wait for the content is over either way.
        CATransaction.setMainCompletion { [weak self] in self?.finish() }
        for layer in layers {
            let hold = CAKeyframeAnimation(keyPath: "opacity")
            let rest = NSNumber(value: -layer.opacity)
            hold.values = [rest, rest, NSNumber(value: 0)]
            hold.keyTimes = [0, NSNumber(value: holdSeconds / total), 1]
            hold.timingFunctions = [CAMediaTimingFunction(name: .linear), gate.fadeCurve]
            hold.isAdditive = true
            hold.duration = total
            hold.beginTime = layer.convertTime(now, from: nil)
            layer.add(hold, forKey: Self.holdKey)
        }
        CATransaction.commit()
    }

    /// The content drew its first frame: while the hold still holds, its fade starts now from 0 (the opacity
    /// shown); once the hold's own fade runs, that fade goes on.
    public func contentDrawn() {
        guard !isSettled else { return }
        isSettled = true
        guard CACurrentMediaTime() < holdEnds, let view else { return }
        for layer in layers { layer.removeAnimation(forKey: Self.holdKey) }
        gate.fadeIn(token, layers: layers, in: view)
    }

    /// Shows the layers at rest now (the pane went away, or a newer change takes it over). `ended` does not run:
    /// the caller ends what it tracks itself.
    public func cancel() {
        isSettled = true
        ended = nil
        let stop = stopWaiting
        stopWaiting = {}
        stop()
        for layer in layers { layer.removeAnimation(forKey: Self.holdKey) }
    }

    private func finish() {
        isSettled = true
        let ended = self.ended
        self.ended = nil
        ended?(self)
    }
}
