public import QuartzCore

/// Hover marquee of a truncated title (tabs, sidebar rows): after the
/// pointer rests for `delay`, the title scrolls at a reading pace to show
/// its end, holds, and springs back (plans/cmux-next/motion.md).
public nonisolated enum MotionMarquee {
    /// Pointer rest before the scroll starts (hover intent, so a pointer
    /// sweeping across tabs never starts one).
    public static var delay: TimeInterval { MotionTunables.marqueeDelay.value }
    /// Scroll speed. Slow enough to read while it moves.
    public static var pointsPerSecond: Double { MotionTunables.marqueeSpeed.value }
    /// Shortest scroll, so a few clipped points do not flick past.
    public static var minimumScroll: TimeInterval { MotionTunables.marqueeMinimumScroll.value }
    /// Pause at the end before it returns.
    public static var hold: TimeInterval { MotionTunables.marqueeHold.value }
    /// Travel under this many points is not worth a marquee.
    public static var minimumTravel: Double { MotionTunables.marqueeMinimumTravel.value }
}

/// Timing of one marquee pass, in seconds from its start.
public nonisolated struct MarqueeTiming: Equatable, Sendable {
    public var delay: TimeInterval
    public var scroll: TimeInterval
    public var hold: TimeInterval
    public var back: TimeInterval
    /// Scroll + hold + back (the delay comes before it).
    public var total: TimeInterval { scroll + hold + back }
}

extension MotionPolicy {
    /// The marquee for `travel` points, or nil when it should not run:
    /// nothing to reveal, animations off, or Reduce Motion (the full
    /// title is then in the tooltip or hover card only).
    public func marquee(travel: Double) -> MarqueeTiming? {
        guard animatesMovement, travel >= MotionMarquee.minimumTravel else { return nil }
        let scale = speed.timeScale
        return MarqueeTiming(
            delay: MotionMarquee.delay * scale,
            scroll: max(MotionMarquee.minimumScroll, travel / MotionMarquee.pointsPerSecond) * scale,
            hold: MotionMarquee.hold * scale,
            back: duration(MotionSpring.move)
        )
    }
}

extension Motion {
    /// One marquee pass on `keyPath` (a `transform.translation.x`) from 0 to
    /// `-travel` and back, starting `delay` after `now` (Core Animation
    /// holds the start value until then: no timer runs in the app). `sign`
    /// is -1 for the text and +1 for a mask that must stay put on screen
    /// while the text moves under it. Nil when the marquee should not run.
    public static func marqueeAnimation(keyPath: String, travel: CGFloat, sign: CGFloat, now: CFTimeInterval,
                                        policy: MotionPolicy = Motion.policy) -> CAAnimation? {
        guard let timing = policy.marquee(travel: Double(travel)) else { return nil }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        let end = sign * travel
        animation.values = [CGFloat(0), end, end, CGFloat(0)]
        let total = timing.total
        animation.keyTimes = [0, timing.scroll / total, (timing.scroll + timing.hold) / total, 1].map { NSNumber(value: $0) }
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            fadeCurve,
        ]
        animation.duration = total
        animation.beginTime = now + timing.delay
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        return animation
    }
}
