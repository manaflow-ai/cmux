public import QuartzCore

/// Presentation-only Core Animation objects for one policy, for a caller that
/// adds them under its own keys and never changes the layer's model value
/// (a sidebar card's entrance and exit). `Motion.set` writes the model; these
/// do not.
extension MotionPolicy {
    /// A `token` fade of `keyPath` from `from` to `to`, or nil when the
    /// token's duration is 0 (speed off).
    public func fadeAnimation(_ token: MotionFade, _ keyPath: String, from: Any, to: Any,
                              curve: CAMediaTimingFunctionName = .easeOut) -> CABasicAnimation? {
        let duration = self.duration(token)
        guard duration > 0 else { return nil }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: curve)
        return animation
    }

    /// The `token` spring from `from` to `to` on `keyPath`, run until it
    /// settles within 0.2 % of the distance.
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

    /// A `token` crossfade of a layer's next contents change, or nil when
    /// the token's duration is 0 (speed off).
    public func fadeTransition(_ token: MotionFade) -> CATransition? {
        let duration = self.duration(token)
        guard duration > 0 else { return nil }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return transition
    }
}
