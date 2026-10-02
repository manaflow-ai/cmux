public import AppKit
public import QuartzCore
import SwiftUI

/// AppKit entry points. `NSAnimationContext.animate(_:)` with a SwiftUI
/// animation is retargetable: a new change starts from the view's current
/// presentation value and keeps its velocity, so nothing jumps or queues.
extension Motion {
    /// Animates `NSView.animator()` changes with a spring token, or applies
    /// them at once when movement does not animate. `completion` runs on the
    /// main thread after the change finishes (or on the next turn).
    public static func animate(_ token: MotionSpring, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard animatesMovement else { return withoutAnimation(changes, completion: completion) }
        let spring = self.spring(token)
        let animation = Animation.spring(response: spring.response, dampingFraction: spring.dampingFraction, blendDuration: 0)
        NSAnimationContext.animate(animation, changes: changes, completion: traced("appkit.\(token.rawValue)", completion))
    }

    /// Animates `NSView.animator()` opacity or color changes with a fade token.
    public static func animate(_ token: MotionFade, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let duration = self.duration(token)
        guard duration > 0 else { return withoutAnimation(changes, completion: completion) }
        NSAnimationContext.animate(.easeOut(duration: duration), changes: changes, completion: traced("appkit.\(token.rawValue)", completion))
    }

    /// Timed animation for animators that do not take SwiftUI springs
    /// (NSWindow frame and alpha, implicit subview layout inside the block):
    /// `token`'s perceived duration with the fade curve.
    public static func animateTimed(_ token: MotionSpring, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let duration = self.duration(token)
        runTimed(duration, changes, completion: duration > 0 ? traced("timed.\(token.rawValue)", completion) : completion)
    }

    /// Timed animation with a fade token (NSWindow alpha).
    public static func animateTimed(_ token: MotionFade, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let duration = self.duration(token)
        runTimed(duration, changes, completion: duration > 0 ? traced("timed.\(token.rawValue)", completion) : completion)
    }

    /// Opens a `MotionTrace` span now and closes it when `completion` runs.
    private static func traced(_ name: String, _ completion: (@MainActor @Sendable () -> Void)?) -> (@MainActor @Sendable () -> Void)? {
        guard MotionTrace.isEnabled else { return completion }
        MotionTrace.begin(name)
        return {
            MotionTrace.end(name)
            completion?()
        }
    }

    private static func runTimed(_ duration: TimeInterval, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)?) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = fadeCurve
            context.allowsImplicitAnimation = duration > 0
            changes()
        }, completionHandler: completion.map { done in { @Sendable in MainActor.assumeIsolated { done() } } })
    }

    /// Applies `animator()` changes at once (a zero-length group, so implicit
    /// animations do not start either).
    public static func withoutAnimation(_ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            changes()
        }, completionHandler: completion.map { done in { @Sendable in MainActor.assumeIsolated { done() } } })
    }

    // MARK: Core Animation

    /// Runs `changes` in a CATransaction whose implicit actions use `token`,
    /// or with actions disabled when `token` is nil or does not animate.
    /// Implicit actions interpolate from the presentation value, so a change
    /// mid-fade continues from what is on screen.
    public static func transaction(_ token: MotionFade?, _ changes: () -> Void) {
        let duration = token.map(self.duration) ?? 0
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(fadeCurve)
        } else {
            CATransaction.setDisableActions(true)
        }
        changes()
        CATransaction.commit()
    }

    /// `transaction(_:_:)` for layer geometry (progress bars): the spring's
    /// perceived duration, instant when movement does not animate.
    public static func transaction(spring token: MotionSpring, _ changes: () -> Void) {
        let duration = self.duration(token)
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(fadeCurve)
        } else {
            CATransaction.setDisableActions(true)
        }
        changes()
        CATransaction.commit()
    }

    /// A layer action for properties that fade (`CALayer.actions`). Its
    /// duration is 0, so it takes the enclosing `transaction(_:_:)`'s token.
    public static var fadeAction: CABasicAnimation {
        let animation = CABasicAnimation()
        animation.timingFunction = fadeCurve
        return animation
    }

    /// The value on screen: the presentation layer's, else the model's.
    public static func presentationValue(_ layer: CALayer, _ keyPath: String) -> Any? {
        (layer.presentation() ?? layer).value(forKeyPath: keyPath)
    }

    /// Sets `layer.keyPath` to `value` with a spring that starts from the
    /// current presentation value (`from` overrides the sample). Returns the
    /// added animation, or nil when the change applied at once.
    @discardableResult
    public static func set(_ layer: CALayer, _ keyPath: String, to value: Any, spring token: MotionSpring, from: Any? = nil) -> CAAnimation? {
        let start = from ?? presentationValue(layer, keyPath)
        setModel(layer, keyPath, value)
        guard animatesMovement, let start else {
            layer.removeAnimation(forKey: keyPath)
            return nil
        }
        let spring = self.spring(token)
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.duration = spring.settlingTime(within: 0.002)
        animation.fromValue = start
        animation.toValue = value
        add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).\(token.rawValue)")
        return animation
    }

    /// Adds `animation`, closing a `MotionTrace` span when it ends.
    private static func add(_ animation: CAAnimation, to layer: CALayer, keyPath: String, trace: String) {
        guard MotionTrace.isEnabled else { return layer.add(animation, forKey: keyPath) }
        MotionTrace.begin(trace)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { MotionTrace.end(trace) } }
        layer.add(animation, forKey: keyPath)
        CATransaction.commit()
    }

    /// Sets `layer.keyPath` to `value` with a timed fade from the current
    /// presentation value. Returns the added animation, or nil.
    @discardableResult
    public static func set(_ layer: CALayer, _ keyPath: String, to value: Any, fade token: MotionFade, from: Any? = nil) -> CAAnimation? {
        let start = from ?? presentationValue(layer, keyPath)
        setModel(layer, keyPath, value)
        let duration = self.duration(token)
        guard duration > 0, let start else {
            layer.removeAnimation(forKey: keyPath)
            return nil
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = duration
        animation.timingFunction = fadeCurve
        animation.fromValue = start
        animation.toValue = value
        add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).\(token.rawValue)")
        return animation
    }

    private static func setModel(_ layer: CALayer, _ keyPath: String, _ value: Any) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
    }

    // MARK: Loops

    /// A continuous rotation for a busy spinner, or nil when loops are off.
    public static func spinAnimation() -> CAAnimation? {
        guard let period = period(.spinner) else { return nil }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi
        spin.duration = period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        return spin
    }

    /// A rotation in `steps` discrete jumps per turn (the native spinner's
    /// spoke-to-spoke motion), one turn per `spinner` period, or nil when
    /// loops are off. Runs in the render server like `spinAnimation`.
    public static func stepAnimation(steps: Int) -> CAAnimation? {
        guard let period = period(.spinner), steps >= 2 else { return nil }
        let step = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        step.values = (0..<steps).map { -2 * CGFloat.pi * CGFloat($0) / CGFloat(steps) }
        step.calculationMode = .discrete
        step.duration = period
        step.repeatCount = .infinity
        step.isRemovedOnCompletion = false
        return step
    }

    /// Steps a layer's `contents` through `frames`, one cycle per `spinner`
    /// period, or nil when loops are off (the layer keeps its first frame).
    /// Runs in the render server like `spinAnimation`.
    public static func framesAnimation(_ frames: [CGImage]) -> CAAnimation? {
        guard let period = period(.spinner), frames.count >= 2 else { return nil }
        let step = CAKeyframeAnimation(keyPath: "contents")
        step.values = frames
        step.calculationMode = .discrete
        step.duration = period
        step.repeatCount = .infinity
        step.isRemovedOnCompletion = false
        return step
    }

    /// An opacity pulse (1 -> `low` -> 1), or nil when loops are off.
    public static func pulseAnimation(low: Float) -> CAAnimation? {
        guard let period = period(.pulse) else { return nil }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = low
        pulse.duration = period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        return pulse
    }

    /// Attention flash: two blinks, one fade under Reduce Motion, nil when off.
    public static func flashAnimation() -> CAAnimation? {
        guard animatesFades else { return nil }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        if animatesLoops {
            flash.values = [0, 1, 1, 0, 1, 0]
            flash.duration = MotionLoop.flash.period * speed.timeScale
        } else {
            flash.values = [1, 0]
            flash.duration = MotionLoop.flash.period / 2
        }
        return flash
    }

    /// A crossfade layer action for swapped contents (`CALayer.actions`).
    /// Its duration is 0, so it takes the enclosing `transaction(_:_:)`'s token.
    public static var crossfadeAction: CATransition {
        let transition = CATransition()
        transition.type = .fade
        return transition
    }
}
