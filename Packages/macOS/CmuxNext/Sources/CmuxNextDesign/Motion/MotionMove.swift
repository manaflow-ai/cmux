public import QuartzCore
public import CmuxNextDesignTokens

/// One change of layer model values that the render server shows as motion
/// (perf I7: no main-thread work per frame). The caller writes the new values
/// at once, so hit testing and the next layout read the targets, and adds
/// `additive(_:from:to:)` per changed value: an additive animation from the
/// old value minus the new to zero. A layer shows its old value at the start
/// and its model value at the end; a move that starts while another still
/// runs stacks on it, so it starts from what is on screen with no jump, and a
/// value written with no move (a scroll, a drag) shifts at once while a move
/// in flight keeps running on top of it. Every animation a caller adds in one
/// transaction starts on the same frame (Core Animation's begin time is the
/// commit), so moves of neighbouring layers stay in lockstep.
public struct MotionMove: Sendable {
    enum Curve: Sendable {
        case tween(MotionTween)
        case spring(MotionSpring, MotionGate)
    }

    let curve: Curve
    /// Seconds from the start to rest.
    public let duration: CFTimeInterval

    /// A move on tween `token` (Chrome's tab strip tweens: open, close, move), or nil when the change
    /// applies at once (`gate.duration(token)` is 0: the master switch or `gate`'s category off,
    /// speed off, Reduce Motion, a live resize, or a `ui.animations.newTab` kind that is off).
    public static func tween(_ token: MotionTween, in gate: MotionGate) -> MotionMove? {
        let duration = gate.duration(token)
        return duration > 0 ? MotionMove(curve: .tween(token), duration: duration) : nil
    }

    /// A move on spring `token`, or nil when movement does not animate.
    public static func spring(_ token: MotionSpring, in gate: MotionGate) -> MotionMove? {
        guard gate.animatesMovement else { return nil }
        return MotionMove(curve: .spring(token, gate), duration: gate.spring(token).settlingTime(within: 0.002))
    }

    /// The additive animation of `keyPath` from `offset` (the old value minus the new) to `zero`.
    /// Add it under a key no other move uses, so it stacks instead of replacing one in flight.
    public func additive(_ keyPath: String, from offset: Any, to zero: Any) -> CAAnimation {
        let animation: CABasicAnimation
        switch curve {
        case .tween(let token):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = token.timingFunction
        case .spring(let token, let gate):
            animation = gate.springAnimation(token, keyPath, from: offset, to: zero)
        }
        animation.fromValue = offset
        animation.toValue = zero
        animation.isAdditive = true
        return animation
    }
}

extension MotionTween {
    /// The tween's curve (cmux-motion `TweenCurve`, by its C ABI id) for Core Animation.
    public var timingFunction: CAMediaTimingFunction {
        switch base.curve {
        // EaseOutQuad, Chrome's EASE_OUT 1-(1-t)^2: this Bezier's x is t and its y is 2t-t^2 exactly.
        case 0: CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)
        case 1: CAMediaTimingFunction(name: .easeOut)
        case 2: CAMediaTimingFunction(name: .easeInEaseOut)
        default: CAMediaTimingFunction(name: .linear)
        }
    }
}
