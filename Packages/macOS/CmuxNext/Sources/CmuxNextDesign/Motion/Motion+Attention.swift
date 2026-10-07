public import QuartzCore

/// The pane attention ring's animation (`notifications.attention.style`).
/// Blinks use half the `flash` loop period each; the pulse uses the `pulse`
/// loop and runs for the configured duration only, so nothing loops while
/// idle (architecture.md 5). Reduce Motion: one fade. Off: no animation.
extension Motion {
    /// The ring's opacity once its animation ends: 1 while it persists.
    public static func attentionRestingOpacity(_ settings: AttentionSettings) -> Float {
        settings.style == .none || !settings.persists ? 0 : 1
    }

    /// The opacity animation for a new attention mark, or nil for none.
    public static func attentionAnimation(_ settings: AttentionSettings) -> CAAnimation? {
        guard animatesFades, settings.style != .none else { return nil }
        let rest = attentionRestingOpacity(settings)
        guard animatesLoops else {
            // Reduce Motion: fade in to rest, or a single flash that fades.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = rest > 0 ? [0, 1] : [1, 0]
            fade.duration = duration(.fadeIn)
            return fade
        }
        switch settings.style {
        case .none:
            return nil
        case .steady:
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1]
            fade.duration = duration(.fadeIn)
            return fade
        case .blink:
            let count = min(max(settings.blinkCount, AttentionSettings.blinkRange.lowerBound), AttentionSettings.blinkRange.upperBound)
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            var values: [Float] = []
            for _ in 0..<count { values += [1, 0] }
            values.append(rest)
            blink.values = values
            blink.duration = MotionLoop.flash.period / 2 * Double(count) * speed.timeScale
            return blink
        case .pulse:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = MotionLoop.pulse.period / 2
            pulse.autoreverses = true
            pulse.repeatDuration = min(max(settings.duration, AttentionSettings.durationRange.lowerBound), AttentionSettings.durationRange.upperBound)
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return pulse
        }
    }
}
