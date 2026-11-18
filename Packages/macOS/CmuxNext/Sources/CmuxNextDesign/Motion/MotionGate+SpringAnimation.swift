public import CmuxNextDesignTokens
public import QuartzCore

extension MotionGate {
    /// The spring `spring` of this gate (``spring(_:)``) from `from` to `to` on `keyPath`, with `duration` as its
    /// time: for a caller that adds many animations of one spring in one turn, and reads the motion policy and the
    /// spring's settling time one time for them all.
    public func springAnimation(_ spring: SpringParameters, lasting duration: CFTimeInterval, _ keyPath: String, from: Any,
                                to: Any) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.duration = duration
        animation.fromValue = from
        animation.toValue = to
        return animation
    }
}
