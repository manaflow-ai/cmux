public import QuartzCore
import CoreImage
public import CmuxNextDesignTokens

/// The launch mark's entrance and exit (`LaunchMarkView`), here so their
/// timing stays with the other Motion tokens.
extension MotionGate {
    /// The highlight's sweep on the mark (`sheen`), removed with the other launch animations.
    static let launchSheenKey = "launch.sheen"

    /// Resolves the mark in with `style` over the `launch` fade: `trace`
    /// draws the outline, then fills the body over its second half;
    /// `bloom` condenses the mark from a soft glow, 6% larger, to its crisp
    /// size; `lens` sharpens it from a blur, 4% smaller; `sheen` fades it in
    /// and then sweeps `sheen` across it once a `MotionLoop.sheen` period
    /// until `concealLaunchMark`. No overshoot in any. Under Reduce Motion
    /// each is a plain fade (`duration` caps it) and the sweep never starts;
    /// with animation off the mark just shows.
    public func revealLaunchMark(_ style: LaunchMarkStyle, mark: CALayer, outline: CAShapeLayer, body: CAShapeLayer, sheen: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.opacity = 1
        mark.transform = CATransform3DIdentity
        mark.shadowOpacity = 0
        // The lens's blur, named so `filters.blur.inputRadius` animates it; at rest it is 0.
        mark.filters = style == .lens ? Self.launchBlur() : nil
        outline.strokeEnd = 1
        body.opacity = 1
        sheen.opacity = style == .sheen ? 1 : 0
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
        guard !policy.reduceMotion else {
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
        case .lens:
            fade(mark, "opacity", from: 0, to: 1, length: total)
            fade(mark, "transform", from: CATransform3DMakeScale(0.96, 0.96, 1), to: CATransform3DIdentity, length: total)
            // The radius is no model key (KVC would throw): it only animates, and rests at the filter's 0.
            fade(mark, "filters.blur.inputRadius", from: CGFloat(6), to: CGFloat(0), length: total)
        case .sheen:
            fade(mark, "opacity", from: 0, to: 1, length: total)
            // A loop: it runs until `concealLaunchMark` removes it, and not at all with loops off.
            guard let period = period(.sheen) else { return }
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = Self.sheenStart
            sweep.toValue = Self.sheenEnd
            sweep.duration = period
            sweep.timingFunction = fadeCurve
            // The first pass starts once the mark is in; until then the band rests off the mark.
            sweep.beginTime = sheen.convertTime(CACurrentMediaTime(), from: nil) + total
            sweep.repeatCount = .infinity
            sweep.isRemovedOnCompletion = false
            sheen.add(sweep, forKey: Self.launchSheenKey)
        }
    }

    /// The sheen band's stops at rest: left of the mark, so a mark with no sweep shows none.
    static let sheenStart: [NSNumber] = [-0.6, -0.3, 0]
    /// The band's stops at the end of a pass: right of the mark.
    static let sheenEnd: [NSNumber] = [1, 1.3, 1.6]

    /// Fades in a launch mark's backing (the `lens` tile) with the mark, over the `launch` fade.
    public func revealLaunchBacking(_ layer: CALayer) {
        set(layer, "opacity", to: Float(1), fade: .launch, from: Float(0))
    }

    /// Fades the mark out (`fadeOut`) when content replaces it. Its
    /// entrance and the sheen's sweep stop here, on every layer of the mark.
    public func concealLaunchMark(_ mark: CALayer) {
        for layer in [mark] + (mark.sublayers ?? []) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("launch.") { layer.removeAnimation(forKey: key) }
        }
        mark.filters = nil
        set(mark, "opacity", to: Float(0), fade: .fadeOut)
    }

    /// Fades a launch mark's backing out with the mark (`fadeOut`).
    public func concealLaunchBacking(_ layer: CALayer) {
        set(layer, "opacity", to: Float(0), fade: .fadeOut)
    }

    /// A Gaussian blur at radius 0, named so `filters.blur.inputRadius` animates it.
    private static func launchBlur() -> [CIFilter] {
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 0]) else { return [] }
        filter.name = "blur"
        return [filter]
    }
}
