import QuartzCore

/// CoreAnimation animations for the cursor layer, made from one plan.
extension GlidePlan {
    /// `position` keyframes, one per sample, linear between samples.
    /// The first keyframe is the start point (the glide origin), so the
    /// animation needs no separate `fromValue`.
    public func positionAnimation(from start: CGPoint? = nil) -> CAKeyframeAnimation {
        var values = [NSValue(point: start ?? origin)]
        values.append(contentsOf: samples.map { NSValue(point: CGPoint(x: $0.x, y: $0.y)) })
        return keyframes("position", values: values)
    }

    /// `transform.rotation.z` keyframes that follow the arrow heading.
    public func rotationAnimation() -> CAKeyframeAnimation {
        var values: [NSNumber] = [NSNumber(value: samples.first?.heading ?? 0)]
        values.append(contentsOf: samples.map { NSNumber(value: $0.heading) })
        return keyframes("transform.rotation.z", values: values)
    }

    private func keyframes(_ keyPath: String, values: [Any]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        let last = Double(max(values.count - 1, 1))
        animation.keyTimes = (0..<values.count).map { NSNumber(value: Double($0) / last) }
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }
}
