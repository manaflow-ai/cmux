public import QuartzCore

/// The pane attention ring's animation (`notifications.attention.style`).
/// Blinks use half the `flash` loop period each; the pulse uses the `pulse`
/// loop and runs for the configured duration only, so nothing loops while
/// idle (architecture.md 5). Reduce Motion: one fade. Off: no animation.
extension Motion {
    /// The ring's opacity once its animation ends, while it persists: the look's
    /// steady strength for the steady style (clearly visible), its faint resting
    /// strength after a blink or pulse (`AttentionHighlightLook`).
    public static func attentionRestingOpacity(_ settings: AttentionSettings,
                                               look: AttentionHighlightLook = AttentionHighlightLook.tunable.value) -> Float {
        guard settings.style != .none, settings.persists else { return 0 }
        return settings.style == .steady ? look.steadyOpacity : look.restingOpacity
    }

    /// How far the steady ring's arrival pulse rises over its rest, and how long it takes:
    /// one small, fast swell (motion.md), never a blink.
    static let steadyPulseRise: Float = 0.2
    static let steadyPulseDuration: TimeInterval = 0.3

    /// The opacity animation for a new attention mark, or nil for none. `showing`: the ring
    /// already shows (a further notification), so the steady ring swells from its rest instead
    /// of dropping to nothing first.
    public static func attentionAnimation(_ settings: AttentionSettings,
                                          look: AttentionHighlightLook = AttentionHighlightLook.tunable.value,
                                          showing: Bool = false) -> CAAnimation? {
        guard animatesFades, settings.style != .none else { return nil }
        // Static status indicators (cx-sya4n): the steady ring, no blink or pulse.
        var settings = settings
        if DesignSettings.shared.statusIndicator.animation == .static { settings.style = .steady }
        let rest = attentionRestingOpacity(settings, look: look)
        let peak = look.peakOpacity
        guard animatesLoops else {
            // Reduce Motion: fade in to rest, or a single flash that fades.
            if settings.style == .steady, showing, rest > 0 { return nil }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = rest > 0 ? [0, rest] : [peak, 0]
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
            swell.values = [showing ? rest : 0, min(1, rest + steadyPulseRise), rest]
            swell.keyTimes = [0, 0.4, 1]
            swell.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            swell.duration = steadyPulseDuration * speed.timeScale
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
