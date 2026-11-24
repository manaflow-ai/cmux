public import QuartzCore
public import CmuxNextDesignTokens

extension MotionGate {
    /// A one-shot settle for a mark that just reached its end state (a sidebar row's spinner
    /// turning into its done mark): `keyPath` eases from `value` to the layer's own model value
    /// over the `settle` fade. It is removed when it ends (`isRemovedOnCompletion`, the default),
    /// which is its stop condition: nothing repeats and no timer runs.
    ///
    /// Nil when movement does not animate (the master or category switch off, speed off, Reduce
    /// Motion, a live resize): the end state then shows in one frame.
    public func settleAnimation(_ keyPath: String, from value: Any) -> CAAnimation? {
        let seconds = duration(MotionFade.settle)
        guard animatesMovement, seconds > 0 else { return nil }
        let settle = CABasicAnimation(keyPath: keyPath)
        settle.fromValue = value
        settle.duration = seconds
        settle.timingFunction = fadeCurve
        return settle
    }
}
