public import QuartzCore

/// The pane attention ring's animation (`notifications.attention.style`).
/// Blinks use half the `flash` loop period each; the pulse uses the `pulse`
/// loop and runs for the configured duration only, so nothing loops while
/// idle (architecture.md 5). Reduce Motion: one fade. Off: no animation.
extension Motion {
    /// The ring's opacity once its animation ends: the look's resting
    /// strength while it persists (`AttentionHighlightLook`, faint by default).
    public static func attentionRestingOpacity(_ settings: AttentionSettings,
                                               look: AttentionHighlightLook = AttentionHighlightLook.tunable.value) -> Float {
        settings.style == .none || !settings.persists ? 0 : look.restingOpacity
    }

    /// The opacity animation for a new attention mark, or nil for none.
    public static func attentionAnimation(_ settings: AttentionSettings,
                                          look: AttentionHighlightLook = AttentionHighlightLook.tunable.value) -> CAAnimation? {
        guard animatesFades, settings.style != .none else { return nil }
        let rest = attentionRestingOpacity(settings, look: look)
        let peak = look.peakOpacity
        guard animatesLoops else {
            // Reduce Motion: fade in to rest, or a single flash that fades.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = rest > 0 ? [0, rest] : [peak, 0]
            fade.duration = duration(.fadeIn)
            return fade
        }
        switch settings.style {
        case .none:
            return nil
        case .steady:
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = rest > 0 ? [0, rest] : [0, peak, 0]
            fade.duration = duration(.fadeIn)
            return fade
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
