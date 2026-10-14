public import QuartzCore

/// Late content settles in, it does not pop (cx-sya4n; plans/cmux-next/motion.md "Late
/// content"). Motion is small and local (Leo 2026-10-14): a short fade with a few points of
/// rise, the first few rows of a list a step apart, never a whole pane travelling. The web
/// side is webviews/src/ui/motion.ts with the same numbers.
extension Motion {
    /// Items of a list that get their own stagger step; later ones arrive with the last.
    public static let staggerItems = 4
    /// Seconds between two staggered items.
    public static let staggerStep: TimeInterval = 0.025
    /// Points revealed content rises as it settles.
    public static let revealRise: CGFloat = 3

    /// The delay of item `index` of a list that arrives at once: a short step for the first
    /// few items, none past them. 0 under Reduce Motion and with speed "off".
    // TODO(#20467): also 0 during a live resize once `Motion.isLiveResizing` lands.
    public static func stagger(index: Int) -> TimeInterval {
        guard policy.animatesMovement, index > 0 else { return 0 }
        return Double(min(index, staggerItems - 1)) * staggerStep
    }

    /// Fades `layer` in from clear while it rises `revealRise` points into place on the `appear`
    /// spring, after `stagger(index:)`; under Reduce Motion it only fades, at once. Returns the
    /// added animation, or nil when fades are off. The layer's model values are unchanged.
    @discardableResult
    public static func reveal(_ layer: CALayer, index: Int = 0) -> CAAnimation? {
        let policy = policy
        let fade = policy.duration(MotionFade.fadeIn)
        guard fade > 0 else { return nil }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = layer.opacity
        opacity.duration = fade
        opacity.timingFunction = fadeCurve
        var animation: CAAnimation = opacity
        if policy.animatesMovement {
            // Below its place: down is negative y unless the layer is flipped.
            let below = layer.contentsAreFlipped() ? revealRise : -revealRise
            let rise = springAnimation(.appear, "transform.translation.y", from: below, to: 0)
            rise.duration = policy.spring(.appear).perceivedDuration
            let group = CAAnimationGroup()
            group.animations = [opacity, rise]
            group.duration = max(opacity.duration, rise.duration)
            animation = group
        }
        let delay = stagger(index: index)
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: "cmux.reveal")
        return animation
    }
}
