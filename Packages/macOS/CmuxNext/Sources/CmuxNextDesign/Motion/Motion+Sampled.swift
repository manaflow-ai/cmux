public import QuartzCore
public import CmuxNextDesignTokens

extension Motion {
    /// A keyframe animation of `keyPath` through `values` at even times over `duration`, stepped
    /// linearly between them. For animations whose curve is already in the values: the color
    /// transition samples its curve (cmux-motion `TweenCurve`, cubic Bezier or spring) and its
    /// color mix into them, so Core Animation adds no timing of its own.
    public static func sampledKeyframes(_ keyPath: String, values: [Any], duration: TimeInterval) -> CAAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        let last = max(values.count - 1, 1)
        animation.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(last)) }
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = duration
        return MotionActivity.began(animation)
    }
}
