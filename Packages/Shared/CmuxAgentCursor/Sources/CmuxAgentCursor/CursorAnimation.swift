import QuartzCore

/// Turns a [`GlidePlan`] into CoreAnimation animations for the cursor layer.
public enum CursorAnimation {
    /// `position` keyframes, one per sample, linear between samples.
    /// The first keyframe is the start point (the glide origin), so the
    /// animation needs no separate `fromValue`.
    public static func position(_ plan: GlidePlan, from start: CGPoint? = nil) -> CAKeyframeAnimation {
        let origin = start ?? plan.origin
        var values = [NSValue(point: origin)]
        values.append(contentsOf: plan.samples.map { NSValue(point: CGPoint(x: $0.x, y: $0.y)) })
        return keyframes("position", values: values, plan: plan)
    }

    /// `transform.rotation.z` keyframes that follow the arrow heading.
    public static func rotation(_ plan: GlidePlan) -> CAKeyframeAnimation {
        var values: [NSNumber] = [NSNumber(value: plan.samples.first?.heading ?? 0)]
        values.append(contentsOf: plan.samples.map { NSNumber(value: $0.heading) })
        return keyframes("transform.rotation.z", values: values, plan: plan)
    }

    private static func keyframes(_ keyPath: String, values: [Any], plan: GlidePlan) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        let last = Double(max(values.count - 1, 1))
        animation.keyTimes = (0..<values.count).map { NSNumber(value: Double($0) / last) }
        animation.duration = plan.duration
        animation.calculationMode = .linear
        return animation
    }
}
