public import QuartzCore
public import CmuxNextDesignTokens

/// The pane attention ring's animation (`notifications.attention.style`).
/// Blinks use half the `flash` loop period each; the pulse uses the `pulse`
/// loop and runs for the configured duration only, so nothing loops while
/// idle (architecture.md 5). Reduce Motion: a static ring, no flash. Off: no animation.
extension Motion {
    /// The ring's opacity once its animation ends, while it persists: the look's
    /// steady strength for the steady style (clearly visible), its faint resting
    /// strength after a blink or pulse (`AttentionHighlightLook`).
    public static func attentionRestingOpacity(_ settings: AttentionSettings,
                                               look: AttentionHighlightLook = AttentionHighlightLook.tunable.value) -> Float {
        let style = attentionStyle(settings)
        guard style != .none, settings.ringStyle != .none, settings.persists else { return 0 }
        return style == .steady ? look.steadyOpacity : look.restingOpacity
    }

    /// The style the ring draws: static status indicators (cx-sya4n) and Reduce Motion (a
    /// static ring, unread rings from classic, 2026-10-20) turn a blink or pulse into the steady
    /// ring, for its animation and its rest alike.
    static func attentionStyle(_ settings: AttentionSettings) -> AttentionStyle {
        guard settings.style != .none,
              DesignSettings.shared.statusIndicator.animation == .static || !Motion.indicators.animatesLoops else {
            return settings.style
        }
        return .steady
    }

    /// How far the steady ring's arrival pulse rises over its rest, and how long it takes:
    /// one small, fast swell (motion.md), never a blink. The swell is a one-off arrival, so it
    /// takes the motion scale's ceiling (Leo 2026-10-20; it was 0.3 s).
    static let steadyPulseRise: Float = 0.2
    static let steadyPulseDuration: TimeInterval = MotionScale.large
}

extension MotionGate {
    /// The opacity animation for a new attention mark, or nil for none. `showing`: the ring
    /// already shows (a further notification), so the steady ring swells from its rest instead
    /// of dropping to nothing first.
    public func attentionAnimation(_ settings: AttentionSettings,
                                   look: AttentionHighlightLook = AttentionHighlightLook.tunable.value,
                                   showing: Bool = false) -> CAAnimation? {
        guard animatesFades, settings.drawsRing else { return nil }
        // Static status indicators (cx-sya4n): the steady ring, no blink or pulse.
        var settings = settings
        settings.style = Motion.attentionStyle(settings)
        let rest = Motion.attentionRestingOpacity(settings, look: look)
        let peak = look.peakOpacity
        guard animatesLoops else {
            // Reduce Motion: the ring shows at once at its rest, no flash (unread rings from
            // classic, 2026-10-20). A ring that rests invisible (the Flash only look, or
            // `persist` off) fades out once, or nothing would show.
            if rest > 0 { return nil }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [peak, 0]
            fade.duration = duration(.fadeIn)
            return fade
        }
        switch settings.style {
        case .none:
            return nil
        case .steady:
            let swell = CAKeyframeAnimation(keyPath: "opacity")
            guard rest > 0 else {
                swell.values = [0, peak, 0]
                swell.duration = duration(.fadeIn)
                return swell
            }
            swell.values = [showing ? rest : 0, min(1, rest + Motion.steadyPulseRise), rest]
            swell.keyTimes = [0, 0.4, 1]
            swell.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            swell.duration = Motion.steadyPulseDuration * speed.timeScale
            return swell
        case .blink:
            let count = min(max(settings.blinkCount, AttentionSettings.blinkRange.lowerBound), AttentionSettings.blinkRange.upperBound)
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            var values: [Float] = []
            for _ in 0..<count { values += [peak, 0] }
            values.append(rest)
            blink.values = values
            blink.duration = MotionLoop.flash.period / 2 * Double(count) * speed.timeScale
            return blink
        case .pulse:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = peak
            pulse.toValue = peak * 0.3
            pulse.duration = MotionLoop.pulse.period / 2
            pulse.autoreverses = true
            pulse.repeatDuration = min(max(settings.duration, AttentionSettings.durationRange.lowerBound), AttentionSettings.durationRange.upperBound)
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            guard rest != peak else { return pulse }
            // The pulse ends at its peak: settle to the resting strength
            // instead of jumping to it.
            let settle = CABasicAnimation(keyPath: "opacity")
            settle.fromValue = peak
            settle.toValue = rest
            settle.beginTime = pulse.repeatDuration
            settle.duration = duration(.fadeIn)
            let group = CAAnimationGroup()
            group.animations = [pulse, settle]
            group.duration = pulse.repeatDuration + settle.duration
            return group
        }
    }
}

extension MotionGate {
    /// The flash a ring plays as it goes away because the person went into its pane: cmux
    /// classic's dismiss flash, `FocusFlashPattern.doubleBlink` (origin/main
    /// `Sources/Panels/Panel.swift`). Each of the `blinkCount` blinks (two by default, as in
    /// classic) rises from no ring to full strength with ease-out and falls with ease-in, at even
    /// key times, ending with no ring. Classic ran two blinks in 0.9 s; the 2 Hz cap
    /// (`MotionLoop.shortestFlashCycle`) holds two blinks to one `flash` loop period (1 s or more).
    /// Static status indicators (cx-sya4n) get one fade out; Reduce Motion, no ring style, or
    /// animations off get none: the ring just goes.
    public func attentionDismissAnimation(_ settings: AttentionSettings,
                                          look: AttentionHighlightLook = AttentionHighlightLook.tunable.value) -> CAAnimation? {
        guard animatesFades, animatesLoops, settings.drawsRing else { return nil }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        guard DesignSettings.shared.statusIndicator.animation != .static else {
            flash.values = [Motion.attentionRestingOpacity(settings, look: look), 0]
            flash.duration = duration(.fadeIn)
            return flash
        }
        let count = min(max(settings.blinkCount, AttentionSettings.blinkRange.lowerBound), AttentionSettings.blinkRange.upperBound)
        var values: [Float] = [0]
        for _ in 0..<count { values += [1, 0] }
        flash.values = values
        flash.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(values.count - 1)) }
        let rise = CAMediaTimingFunction(name: .easeOut), fall = CAMediaTimingFunction(name: .easeIn)
        flash.timingFunctions = (0..<count).flatMap { _ in [rise, fall] }
        flash.duration = max(MotionLoop.flash.minimumPeriod, MotionLoop.flash.period * speed.timeScale) / 2 * Double(count)
        return flash
    }

    /// The ring's stronger glow held for the length of its dismiss flash (classic's
    /// `flashRingStyle`): the shadow opacity and blur radius stay at the given values for
    /// `duration` seconds, then return to the layer's own. Nil when fades are off.
    public func attentionGlowHold(opacity: Float, radius: CGFloat, duration: TimeInterval) -> CAAnimation? {
        guard animatesFades, duration > 0 else { return nil }
        func hold(_ key: String, _ value: Double) -> CABasicAnimation {
            let hold = CABasicAnimation(keyPath: key)
            hold.fromValue = value
            hold.toValue = value
            hold.duration = duration
            return hold
        }
        let group = CAAnimationGroup()
        group.animations = [hold("shadowOpacity", Double(opacity)), hold("shadowRadius", Double(radius))]
        group.duration = duration
        return group
    }
}
