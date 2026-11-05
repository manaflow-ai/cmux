public import AppKit
public import QuartzCore
import SwiftUI
import CmuxNextWakeups
public import CmuxNextDesignTokens

/// AppKit entry points. On macOS 15 and later a spring token runs as
/// `NSAnimationContext.animate(_:)` with a SwiftUI spring, which retargets: a
/// new change starts from the view's current presentation value and keeps its
/// velocity, so nothing jumps or queues. On macOS 14 (no SwiftUI-animation
/// `NSAnimationContext`) the same token runs as a timed curve: a new change
/// starts from the presentation value but with zero velocity. The timed, exit
/// and fade helpers drop velocity on every macOS. Pane layout motion does not
/// use these entry points: it steps its own springs from the display link
/// (`ScreenContentView+Motion`), which keep value and velocity on every macOS.
extension Motion {
    /// Whether a change of `view` can animate. A window with no screen (a
    /// display unplugged, a screenless host, an offscreen window) or on a
    /// sleeping display (``DisplaySleep``) never advances an AppKit
    /// animation, so its final value and its completion would wait for an
    /// indefinite time; such a change applies at once. Decided per animation,
    /// from the animated view's window or its visible parent window. Child
    /// panels used for overlays can briefly have no screen of their own while
    /// their parent is already on screen. A view outside a window, or no view,
    /// animates as before. A change already running when the display goes
    /// to sleep ends at once only if it opted in (`settleAtSleep`).
    ///
    /// A window out of the person's sight (``FrameScheduler/windowIsOutOfSight(_:)``:
    /// shown once, now ordered out, minimized or fully covered), or a child of
    /// one, never animates either: its change applies at once and its
    /// completion runs now, as Chrome gives a hidden tab no animation frames.
    public static func canAnimate(in view: NSView?) -> Bool {
        guard let firstWindow = view?.window else { return true }
        // AppKit windows have a short, finite child-parent chain. Keep these traversals bounded so
        // malformed test doubles cannot turn a hot-path motion decision into an unbounded loop.
        var shown: NSWindow? = firstWindow
        for _ in 0..<8 {
            guard let current = shown else { break }
            if FrameScheduler.windowIsOutOfSight(current) { return false }
            shown = current.parent
        }
        var window = firstWindow
        for _ in 0..<8 {
            if let screen = window.screen {
                return !DisplaySleep.shared.isAsleep(screen)
            }
            guard let parent = window.parent else { return false }
            window = parent
        }
        return false
    }

    /// The proxy to set a constraint through inside a Motion animation of
    /// `view`: its animator, or the constraint itself when `view`'s window
    /// has no screen. A constraint animator does not apply its value without
    /// a screen, even in a zero-length group, so the constant must be set
    /// directly there.
    public static func animator(_ constraint: NSLayoutConstraint, in view: NSView?) -> NSLayoutConstraint {
        canAnimate(in: view) ? constraint.animator() : constraint
    }

    /// Applies `animator()` changes at once and runs `completion` now (no
    /// display advances an animation group, so its handler cannot be awaited).
    static func snap(_ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)?) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            changes()
        }
        completion?()
    }

    /// Opens a `MotionTrace` span now and closes it when `completion` runs.
    static func traced(_ name: String, _ completion: (@MainActor @Sendable () -> Void)?) -> (@MainActor @Sendable () -> Void)? {
        guard MotionTrace.isEnabled else { return completion }
        MotionTrace.begin(name)
        return {
            MotionTrace.end(name)
            completion?()
        }
    }

    static func runTimed(_ duration: TimeInterval, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)?,
                                 curve: CAMediaTimingFunction? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = curve ?? fadeCurve
            context.allowsImplicitAnimation = duration > 0
            changes()
        }, completionHandler: completion.map { done in { @Sendable in MainDelivery().run(done) } })
    }

    /// Applies `animator()` changes at once (a zero-length group, so implicit
    /// animations do not start either).
    public static func withoutAnimation(_ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            changes()
        }, completionHandler: completion.map { done in { @Sendable in MainDelivery().run(done) } })
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

    /// An animation that shows `keyPath` at `value` until it is replaced or
    /// removed, whatever is written to the model meanwhile.
    public static func hold(_ keyPath: String, at value: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.toValue = value
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Adds `animation`, closing a `MotionTrace` span when it ends.
    static func add(_ animation: CAAnimation, to layer: CALayer, keyPath: String, trace: String) {
        guard MotionTrace.isEnabled else { return layer.add(animation, forKey: keyPath) }
        MotionTrace.begin(trace)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { MotionTrace.end(trace) } } // main-proof: CATransaction.h: the completion block is called on the main thread
        layer.add(animation, forKey: keyPath)
        CATransaction.commit()
    }

    /// Writes the model value with no implicit action. A `set` brackets this and its `add` in one
    /// outer transaction: on its own each commits to the render server, and with no
    /// transaction already open (a socket or timer turn) a frame could show the new model value before
    /// the animation that starts from the old one: a dialog flashed in at full opacity for one frame,
    /// then faded in from zero (debug.dialog_strip, 1 open in 5).
    static func setModel(_ layer: CALayer, _ keyPath: String, _ value: Any) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
    }

    /// A crossfade layer action for swapped contents (`CALayer.actions`).
    /// Its duration is 0, so it takes the enclosing `transaction(_:_:)`'s token.
    public static var crossfadeAction: CATransition {
        let transition = CATransition()
        transition.type = .fade
        return transition
    }

    /// A short in-place title replacement that enters from below. Callers set
    /// the token duration before adding it to their layer.
    public static var pushUpAction: CATransition {
        let transition = CATransition()
        transition.type = .push
        transition.subtype = .fromBottom
        return transition
    }
}

/// The animation helpers of a ``MotionGate``: each decides with its
/// category's policy (`Motion.sidebar.animate(...)`).
extension MotionGate {
    /// Animates `NSView.animator()` changes with a spring token, or applies
    /// them at once when movement does not animate. `completion` runs on the
    /// main thread after the change finishes (or on the next turn).
    ///
    /// - Parameter view: The view the change animates. When its window has no
    ///   screen the change applies at once (``canAnimate(in:)``).
    public func animate(_ token: MotionSpring, in view: NSView? = nil, _ changes: () -> Void,
                               completion: (@MainActor @Sendable () -> Void)? = nil) {
        animateSpring(token, in: view, changes, settleAtSleep: nil, completion: completion)
    }

    /// Animates `NSView.animator()` opacity or color changes with a fade token.
    public func animate(_ token: MotionFade, in view: NSView? = nil, _ changes: () -> Void,
                               completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard canAnimate(in: view) else { return snap(changes, completion: completion) }
        let duration = self.duration(token)
        guard duration > 0 else { return withoutAnimation(changes, completion: completion) }
        guard #available(macOS 15, *) else {
            return runTimed(duration, changes, completion: traced("appkit.\(token.rawValue)", completion))
        }
        NSAnimationContext.animate(.easeOut(duration: duration), changes: changes, completion: traced("appkit.\(token.rawValue)", completion))
    }

    /// Timed animation for animators that do not take SwiftUI springs
    /// (NSWindow frame and alpha, implicit subview layout inside the block):
    /// `token`'s perceived duration with the fade curve.
    public func animateTimed(_ token: MotionSpring, in view: NSView? = nil, _ changes: () -> Void,
                                    completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard canAnimate(in: view) else { return snap(changes, completion: completion) }
        let duration = self.duration(token)
        runTimed(duration, changes, completion: duration > 0 ? traced("timed.\(token.rawValue)", completion) : completion)
    }

    /// An exit: `token`'s duration on a slow-start curve, so a change reversed soon after it
    /// started (the pointer passing over a hover region) barely moved (no timer, no hold).
    public func animateExit(_ token: MotionSpring, in view: NSView? = nil, _ changes: () -> Void,
                                   completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard canAnimate(in: view) else { return snap(changes, completion: completion) }
        let duration = self.duration(token)
        runTimed(duration, changes, completion: duration > 0 ? traced("exit.\(token.rawValue)", completion) : completion,
                 curve: CAMediaTimingFunction(controlPoints: 0.7, 0, 0.3, 1))
    }

    /// Timed animation with a fade token (NSWindow alpha).
    public func animateTimed(_ token: MotionFade, in view: NSView? = nil, _ changes: () -> Void,
                                    completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard canAnimate(in: view) else { return snap(changes, completion: completion) }
        let duration = self.duration(token)
        runTimed(duration, changes, completion: duration > 0 ? traced("timed.\(token.rawValue)", completion) : completion)
    }

    /// Runs `changes` in a CATransaction whose implicit actions use `token`,
    /// or with actions disabled when `token` is nil or does not animate.
    /// Implicit actions interpolate from the presentation value, so a change
    /// mid-fade continues from what is on screen.
    public func transaction(_ token: MotionFade?, _ changes: () -> Void) {
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
    public func transaction(spring token: MotionSpring, _ changes: () -> Void) {
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

    /// Sets `layer.keyPath` to `value` with a spring that starts from the
    /// current presentation value (`from` overrides the sample). Returns the
    /// added animation, or nil when the change applied at once.
    @discardableResult
    public func set(_ layer: CALayer, _ keyPath: String, to value: Any, spring token: MotionSpring, from: Any? = nil) -> CAAnimation? {
        let start = from ?? presentationValue(layer, keyPath)
        // One commit for the model value and its animation (see `Motion.setModel`).
        CATransaction.begin()
        defer { CATransaction.commit() }
        Motion.setModel(layer, keyPath, value)
        guard animatesMovement, let start else {
            layer.removeAnimation(forKey: keyPath)
            return nil
        }
        let animation = springAnimation(token, keyPath, from: start, to: value)
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).\(token.rawValue)")
        return animation
    }

    /// The `token` spring from `from` to `to` on `keyPath`, for a caller
    /// that adds it under its own key (a layer whose model value AppKit
    /// rewrites, as a sidebar space page's translation).
    public func springAnimation(_ token: MotionSpring, _ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let spring = self.spring(token)
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.duration = spring.settlingTime(within: 0.002)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    /// A `token` fade of `keyPath` from `from` to `to` that starts `delay`
    /// seconds from now on `layer` and then holds `to` until removed. At a
    /// zero duration (speed off) it changes at once when the delay ends.
    public func scheduledFade(_ token: MotionFade, _ keyPath: String, from: Any, to: Any, after delay: CFTimeInterval,
                                     on layer: CALayer) -> CABasicAnimation {
        let duration = self.duration(token)
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = duration > 0 ? from : to
        animation.toValue = to
        // A zero duration would run Core Animation's 0.25 s default; a
        // millisecond holds `to` from the end of the wait.
        animation.duration = duration > 0 ? duration : 0.001
        animation.timingFunction = fadeCurve
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Sets `layer.keyPath` to `value` with a timed fade from the current
    /// presentation value. Returns the added animation, or nil.
    @discardableResult
    public func set(_ layer: CALayer, _ keyPath: String, to value: Any, fade token: MotionFade, from: Any? = nil) -> CAAnimation? {
        let start = from ?? presentationValue(layer, keyPath)
        // One commit for the model value and its animation (see `Motion.setModel`).
        CATransaction.begin()
        defer { CATransaction.commit() }
        Motion.setModel(layer, keyPath, value)
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
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).\(token.rawValue)")
        return animation
    }

    /// Sets `layer.keyPath` to `value` over `duration` seconds on the fade
    /// curve, from the current presentation value: a spring token's
    /// perceived duration (``duration(_:)-swift.type.method``) for a pair of
    /// changes that must end together, as a popup's fade and shrink on close.
    @discardableResult
    func set(_ layer: CALayer, _ keyPath: String, to value: Any, duration: TimeInterval, from: Any? = nil) -> CAAnimation? {
        let start = from ?? presentationValue(layer, keyPath)
        // One commit for the model value and its animation (see `Motion.setModel`).
        CATransaction.begin()
        defer { CATransaction.commit() }
        Motion.setModel(layer, keyPath, value)
        guard duration > 0, let start else {
            layer.removeAnimation(forKey: keyPath)
            return nil
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = duration
        animation.timingFunction = fadeCurve
        animation.fromValue = start
        animation.toValue = value
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).timed")
        return animation
    }

    /// A movement (scale, position) timed with a fade token, as a panel's
    /// shrink while it fades out. When movement does not animate (Reduce
    /// Motion, speed "off") the value stays as it is, so only the opacity
    /// crossfade remains (motion.md rule 7): applied at once, a close's
    /// shrink jumped the panel smaller in one frame before it faded.
    @discardableResult
    public func set(_ layer: CALayer, _ keyPath: String, to value: Any, movementFade token: MotionFade, from: Any? = nil) -> CAAnimation? {
        guard animatesMovement else {
            layer.removeAnimation(forKey: keyPath)
            return nil
        }
        return set(layer, keyPath, to: value, fade: token, from: from)
    }

    /// A continuous clockwise rotation for a busy spinner, or nil when loops are off. Clockwise
    /// only: every spinner turns the same way.
    public func spinAnimation() -> CAAnimation? {
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
    public func stepAnimation(steps: Int) -> CAAnimation? {
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
    public func framesAnimation(_ frames: [CGImage]) -> CAAnimation? {
        guard let period = period(.spinner), frames.count >= 2 else { return nil }
        let step = CAKeyframeAnimation(keyPath: "contents")
        step.values = frames
        step.calculationMode = .discrete
        step.duration = period
        step.repeatCount = .infinity
        step.isRemovedOnCompletion = false
        return step
    }

    /// Steps a layer's `contents` through `frames`, each shown for its own `delays` seconds (an
    /// uploaded GIF's own timing, so no token sets it), looping, or nil when loops are off or there
    /// is one frame (the layer keeps its first frame). Runs in the render server like `spinAnimation`.
    public func clipAnimation(_ frames: [CGImage], delays: [TimeInterval]) -> CAAnimation? {
        let total = delays.reduce(0, +)
        guard animatesLoops, frames.count >= 2, delays.count == frames.count, total > 0 else { return nil }
        let clip = CAKeyframeAnimation(keyPath: "contents")
        clip.values = frames
        var start: TimeInterval = 0
        // Discrete: one key time per frame's start, and 1 to close the last frame.
        clip.keyTimes = delays.map { delay in
            defer { start += delay }
            return NSNumber(value: start / total)
        } + [1]
        clip.calculationMode = .discrete
        clip.duration = total
        clip.repeatCount = .infinity
        clip.isRemovedOnCompletion = false
        return clip
    }

    /// Unmeasured progress: a segment (anchored at its left edge) crosses a
    /// track `travel` points wide, entering from its own width left of the
    /// track, once per `sweep` period, or nil when loops are off. The track
    /// clips it.
    /// - Parameter policy: The motion settings to follow (the host's injected policy; nil reads this gate's policy).
    public func sweepAnimation(segment: CGFloat, travel: CGFloat, policy: MotionPolicy? = nil) -> CAAnimation? {
        guard let period = (policy ?? self.policy).period(.sweep), travel > 0 else { return nil }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -segment
        sweep.toValue = travel
        sweep.duration = period
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        sweep.isRemovedOnCompletion = false
        return sweep
    }

    /// Agent work's breath (1 -> `low` -> 1 over one `breath` period, eased), or nil when loops
    /// are off. Slower and softer than the waiting pulse, so a list of working rows reads calm.
    public func breathAnimation(low: Float) -> CAAnimation? {
        guard let period = period(.breath) else { return nil }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = low
        breath.duration = period / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        return breath
    }

    /// An opacity pulse (1 -> `low` -> 1), or nil when loops are off.
    public func pulseAnimation(low: Float) -> CAAnimation? {
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
    /// The blinks peak half a `flash` period apart (the 2 Hz cap,
    /// `MotionLoop.shortestFlashCycle`).
    public func flashAnimation() -> CAAnimation? {
        guard animatesFades else { return nil }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        if animatesLoops {
            flash.values = [0, 1, 0, 1, 0]
            flash.duration = MotionLoop.flash.period * speed.timeScale
        } else {
            flash.values = [1, 0]
            flash.duration = MotionLoop.flash.period / 2
        }
        return flash
    }

    /// Keeps a layer hidden while a `token` move is still more than 3% from
    /// its target, then fades it in: a row another row passes over shows
    /// again once they no longer overlap (cx-ai79). Nil when moves snap.
    public func passOverAnimation(_ token: MotionSpring) -> CAAnimation? {
        guard animatesMovement else { return nil }
        let settle = spring(token).settlingTime(within: 0.03)
        let total = settle + duration(MotionFade.fadeIn)
        let hide = CAKeyframeAnimation(keyPath: "opacity")
        hide.values = [0, 0, 1]
        hide.keyTimes = [0, NSNumber(value: settle / total), 1]
        hide.duration = total
        return hide
    }

    /// Under Reduce Motion, a change that would move things crossfades in place instead
    /// (motion.md rule 7): `layer` fades from what it showed to what it shows after this
    /// transaction. Nil when fades are off.
    @discardableResult
    public func crossfadeInPlace(_ layer: CALayer?) -> CATransition? {
        let seconds = duration(.crossfade)
        guard let layer, seconds > 0 else { return nil }
        let transition = crossfadeAction
        transition.duration = seconds
        transition.timingFunction = fadeCurve
        layer.add(transition, forKey: "cmux.reduceMotionCrossfade")
        return transition
    }
}
