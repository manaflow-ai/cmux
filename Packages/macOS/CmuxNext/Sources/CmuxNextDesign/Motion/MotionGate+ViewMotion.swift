public import AppKit
import CmuxNextWakeups
public import CmuxNextDesignTokens

/// A layer-backed view's frame and alpha, animated on the render server.
///
/// `animate(_:in:_:)` hands an `animator()` change to AppKit, which steps a SwiftUI spring or curve
/// on the main thread and writes the view's frame or alpha every display frame (#24187 measured it
/// for sidebar rows). These helpers set the model value once, in the caller's turn, then add an
/// additive animation from (old - new) to 0 on the view's layer, so main does no work per frame.
/// Chrome's model: `ui::LayerAnimator` (ui/compositor/layer_animator.cc) makes the target bounds and
/// opacity the layer's value at once (`GetTargetBounds`) while cc animates them on the compositor
/// thread (cc/animation/keyframe_model.h). A retarget mid-flight adds one more animation from the
/// old model value: the running ones carry on, so value and velocity stay continuous
/// (SidebarDragSpring uses the same model).
///
/// Each change animates per component (`position.x`, `position.y`, `bounds.size.width`,
/// `bounds.size.height`, `opacity`), all from one begin time. With movement (frame) or fades
/// (alpha) off, out of a window, without a layer or on a sleeping display, the change lands in one
/// frame, a running one of these animations on the view ends with it, and `completion` runs now.
/// When the display sleeps mid-change the animations end (the model is already the target) and
/// `completion` runs (``MotionInFlight``).
@MainActor
extension MotionGate {
    /// Moves `view` to `frame` (its superview's coordinates) with the `token` spring.
    public func set(_ view: NSView, frame: NSRect, spring token: MotionSpring,
                    completion: (@MainActor @Sendable () -> Void)? = nil) {
        let timing = animatesMovement ? ViewTiming.spring(token, spring(token).settlingTime(within: 0.002)) : nil
        setFrame(view, frame, timing, trace: "view.frame.\(token.rawValue)", completion)
    }

    /// Moves `view` to `frame` over `token`'s duration on the fade curve: a short slide that rides
    /// a fade, as "…" does as the pane controls appear.
    public func set(_ view: NSView, frame: NSRect, fade token: MotionFade,
                    completion: (@MainActor @Sendable () -> Void)? = nil) {
        let seconds = duration(token)
        setFrame(view, frame, animatesMovement && seconds > 0 ? ViewTiming.curve(seconds) : nil, trace: "view.frame.\(token.rawValue)", completion)
    }

    /// Fades `view` to `alpha` with `token`.
    public func set(_ view: NSView, alpha: CGFloat, fade token: MotionFade,
                    completion: (@MainActor @Sendable () -> Void)? = nil) {
        let seconds = duration(token)
        let timing = animatesFades && seconds > 0 ? ViewTiming.curve(seconds) : nil
        let trace = "view.alpha.\(token.rawValue)"
        guard let timing, let layer = animatableLayer(of: view) else {
            Self.stop(view.layer, prefix: Self.alphaKey)
            withoutAnimation { view.animator().alphaValue = alpha }
            completion?()
            return
        }
        guard view.alphaValue != alpha else {
            completion?()
            return
        }
        let start = Self.start(of: layer, paths: ["opacity"]).opacity
        withoutAnimation { view.animator().alphaValue = alpha }
        add([("opacity", CGFloat(start - layer.opacity))], to: layer, prefix: Self.alphaKey, timing: timing,
            trace: trace, completion: completion)
    }

    /// The key prefixes of the animations these helpers add (a snap takes only those off).
    static let frameKey = "motion.view.frame"
    static let alphaKey = "motion.view.alpha"

    private enum ViewTiming {
        /// The spring, and its settling time.
        case spring(MotionSpring, TimeInterval)
        /// Seconds on the fade curve.
        case curve(TimeInterval)

        var seconds: TimeInterval {
            switch self {
            case .spring(_, let seconds), .curve(let seconds): seconds
            }
        }
    }

    /// `view`'s layer when a change of it can animate: in a window on an awake display.
    private func animatableLayer(of view: NSView) -> CALayer? {
        guard view.window != nil, canAnimate(in: view) else { return nil }
        return view.layer
    }

    private func setFrame(_ view: NSView, _ frame: NSRect, _ timing: ViewTiming?, trace: String,
                          _ completion: (@MainActor @Sendable () -> Void)?) {
        guard let timing, let layer = animatableLayer(of: view) else {
            Self.stop(view.layer, prefix: Self.frameKey)
            withoutAnimation { view.animator().frame = frame }
            completion?()
            return
        }
        guard view.frame != frame else {
            completion?()
            return
        }
        let start = Self.start(of: layer, paths: ["position", "bounds", "bounds.size", "bounds.origin", "frameOrigin", "frameSize"])
        // Through the animator in a zero-length group: that also stops a move AppKit still runs on the view.
        withoutAnimation { view.animator().frame = frame }
        let deltas: [(String, CGFloat)] = [
            ("position.x", start.position.x - layer.position.x), ("position.y", start.position.y - layer.position.y),
            ("bounds.size.width", start.size.width - layer.bounds.width), ("bounds.size.height", start.size.height - layer.bounds.height),
        ]
        add(deltas.filter { $0.1 != 0 }, to: layer, prefix: Self.frameKey, timing: timing, trace: trace, completion: completion)
    }

    /// Adds one additive animation per `(keyPath, old - new)`, all from one begin time; `completion`
    /// runs once when they end, or when the display sleeps.
    private func add(_ deltas: [(String, CGFloat)], to layer: CALayer, prefix: String, timing: ViewTiming, trace: String,
                     completion: (@MainActor @Sendable () -> Void)?) {
        guard !deltas.isEmpty else {
            completion?()
            return
        }
        let done = MotionInFlight.track(settle: { [weak layer] in Self.stop(layer, prefix: prefix) }, seconds: timing.seconds,
                                        completion: traced(trace, completion))
        // From now, not from the start of this run-loop turn: a long turn would show the first frame already moved.
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil)
        CATransaction.begin()
        CATransaction.setCompletionBlock { @Sendable in MainDelivery().run(done) }
        // A key of its own keeps every running animation: a retarget adds, it never replaces.
        let change = UUID().uuidString
        for (keyPath, delta) in deltas {
            let animation = additive(timing, keyPath, from: delta)
            animation.beginTime = begin
            layer.add(animation, forKey: "\(prefix).\(keyPath).\(change)")
        }
        CATransaction.commit()
    }

    private func additive(_ timing: ViewTiming, _ keyPath: String, from delta: CGFloat) -> CAPropertyAnimation {
        let animation: CAPropertyAnimation
        switch timing {
        case .spring(let token, _):
            animation = springAnimation(token, keyPath, from: NSNumber(value: Double(delta)), to: NSNumber(value: 0))
        case .curve(let seconds):
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.duration = seconds
            basic.timingFunction = fadeCurve
            basic.fromValue = NSNumber(value: Double(delta))
            basic.toValue = NSNumber(value: 0)
            animation = basic
        }
        animation.isAdditive = true
        return animation
    }

    /// Where a change starts: the model, so the additive animations already running keep carrying
    /// their part. A non-additive animation of one of `paths` (an earlier AppKit animator change)
    /// pins the layer to its own end value, so it is replaced by what it shows now.
    private static func start(of layer: CALayer, paths: Set<String>) -> (position: CGPoint, size: CGSize, opacity: Float) {
        let pinning = (layer.animationKeys() ?? []).filter { key in
            guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation, let path = animation.keyPath else { return false }
            return paths.contains(path) && !animation.isAdditive
        }
        guard !pinning.isEmpty, let shown = layer.presentation() else { return (layer.position, layer.bounds.size, layer.opacity) }
        for key in pinning { layer.removeAnimation(forKey: key) }
        return (shown.position, shown.bounds.size, shown.opacity)
    }

    /// Takes this helper's animations under `prefix` off `layer`, so it shows its model value now.
    private static func stop(_ layer: CALayer?, prefix: String) {
        guard let layer else { return }
        for key in layer.animationKeys() ?? [] where key.hasPrefix(prefix + ".") { layer.removeAnimation(forKey: key) }
    }
}
