public import QuartzCore

extension MotionGate {
    /// A pointing glyph's bob: `travel` points of vertical movement centered on its rest place
    /// (half up, half down, so the direction of the layer's y axis does not matter), one bob per
    /// `nudge` period, eased in and out; nil when loops are off (the glyph stays still).
    public func nudgeAnimation(travel: CGFloat) -> CAAnimation? {
        guard let period = period(.nudge), travel > 0 else { return nil }
        let nudge = CABasicAnimation(keyPath: "transform.translation.y")
        nudge.fromValue = -travel / 2
        nudge.toValue = travel / 2
        nudge.duration = period / 2
        nudge.autoreverses = true
        nudge.repeatCount = .infinity
        nudge.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        nudge.isRemovedOnCompletion = false
        return nudge
    }
}
