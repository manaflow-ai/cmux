public import QuartzCore

/// The launch mark's entrance and exit (`LaunchMarkView`), here so their
/// timing stays with the other Motion tokens.
extension Motion {
    /// Resolves the mark in with `style` over the `launch` fade: `trace`
    /// draws the outline, then fills the body over its second half;
    /// `bloom` condenses the mark from a soft glow, 6% larger, to its crisp
    /// size. No overshoot in either. Under Reduce Motion both are a plain
    /// fade (`duration` caps it); with animation off the mark just shows.
    public static func revealLaunchMark(_ style: LaunchMarkStyle, mark: CALayer, outline: CAShapeLayer, body: CAShapeLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.opacity = 1
        mark.transform = CATransform3DIdentity
        mark.shadowOpacity = 0
        outline.strokeEnd = 1
        body.opacity = 1
        CATransaction.commit()
        let total = duration(.launch)
        guard total > 0 else { return }
        let now = mark.convertTime(CACurrentMediaTime(), from: nil)
        func fade(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, length: TimeInterval, delay: TimeInterval = 0) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = length
            animation.timingFunction = fadeCurve
            if delay > 0 {
                animation.beginTime = now + delay
                animation.fillMode = .backwards
            }
            layer.add(animation, forKey: "launch.\(keyPath)")
        }
        guard !reduceMotion else {
            fade(mark, "opacity", from: 0, to: 1, length: total)
            return
        }
        switch style {
        case .trace:
            fade(mark, "opacity", from: 0, to: 1, length: total / 4)
            fade(outline, "strokeEnd", from: 0, to: 1, length: total)
            fade(body, "opacity", from: 0, to: 1, length: total / 2, delay: total / 2)
        case .bloom:
            fade(mark, "opacity", from: 0, to: 1, length: total)
            fade(mark, "transform", from: CATransform3DMakeScale(1.06, 1.06, 1), to: CATransform3DIdentity, length: total)
            fade(mark, "shadowOpacity", from: 0.7, to: 0, length: total)
        }
    }

    /// Fades the mark out (`fadeOut`) when content replaces it.
    public static func concealLaunchMark(_ mark: CALayer) {
        for key in mark.animationKeys() ?? [] where key.hasPrefix("launch.") { mark.removeAnimation(forKey: key) }
        set(mark, "opacity", to: Float(0), fade: .fadeOut)
    }
}
