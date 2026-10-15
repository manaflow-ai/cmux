public import QuartzCore

extension MotionTunables {
    /// Default length of a color change before cmux.json applies (`appearance.colorTransition.duration`,
    /// whose own default is the same 200 ms; schemas/settings/source/color-transition.json).
    public static let colorTransitionDuration = Tunable<Double>.number(
        "motion.colorTransition.duration", .fades, "Color change", help: "Default length of a theme or color change (appearance.colorTransition.duration).",
        default: 0.2, range: 0...2, step: 0.01, unit: .seconds, code: "MotionTunables.colorTransitionDuration")
}

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
        return animation
    }
}
