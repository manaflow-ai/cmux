import QuartzCore
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The opt-in steady ring (blink is the default style) is clearly visible and arrives with
/// one short soft pulse (Leo, 2026-10-14: the steady ring settled at the old faint resting
/// level, so a new notification barely showed; steady, no blink, one small fast pulse at most).
@MainActor @Suite(.serialized) struct AttentionSteadyTests {
    private var steady: AttentionSettings {
        var settings = AttentionSettings()
        settings.style = .steady
        return settings
    }

    private func opacities(_ animation: CAAnimation?) -> [Float] {
        ((animation as? CAKeyframeAnimation)?.values ?? []).compactMap { ($0 as? NSNumber)?.floatValue }
    }

    @Test func steadyRingRestsVisibly() {
        // The blink's own rest needs its animated look: Reduce Motion or the static look (both
        // process-wide, set by suites that run alongside) turn it into the steady ring.
        let design = DesignSettings.shared
        let before = (indicator: design.statusIndicator, reduceMotion: Motion.reduceMotionOverride)
        design.statusIndicator.animation = .animated
        Motion.reduceMotionOverride = false
        defer {
            design.statusIndicator = before.indicator
            Motion.reduceMotionOverride = before.reduceMotion
        }
        let rest = Motion.attentionRestingOpacity(steady, look: .subtle)
        #expect(rest >= 0.65, "steady rests at \(rest): too faint to notice")
        // The blink keeps its faint rest after its flashes.
        var blink = AttentionSettings()
        blink.style = .blink
        #expect(Motion.attentionRestingOpacity(blink, look: .subtle) == AttentionHighlightLook.subtle.restingOpacity)
    }

    @Test func steadyRingArrivesWithOneSmallFastPulse() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let animation = try #require(Motion.indicators.attentionAnimation(steady, look: .subtle))
        let values = opacities(animation)
        let rest = Motion.attentionRestingOpacity(steady, look: .subtle)
        #expect(values.first == 0)
        #expect(values.last == rest)
        let peak = try #require(values.max())
        #expect(peak > rest, "no pulse: \(values)")
        #expect(peak - rest <= 0.3, "the pulse is not small: \(values)")
        let rises = zip(values, values.dropFirst()).filter { $0 < $1 }.count
        #expect(rises == 1, "more than one pulse: \(values)")
        #expect(animation.duration <= 0.4, "the pulse is not fast: \(animation.duration)s")
    }

    /// Reduce Motion: no flash, a static ring (unread rings from classic, Lawrence 2026-10-20).
    /// Every style shows the steady ring at once, as the static look does.
    @Test(arguments: [AttentionStyle.steady, .blink, .pulse])
    func reduceMotionShowsAStaticRing(_ style: AttentionStyle) throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        var settings = AttentionSettings()
        settings.style = style
        #expect(Motion.indicators.attentionAnimation(settings, look: .subtle) == nil, "\(style) animates under Reduce Motion")
        let rest = Motion.attentionRestingOpacity(settings, look: .subtle)
        #expect(rest == AttentionHighlightLook.subtle.steadyOpacity, "\(style) rests at \(rest), not the steady strength")
    }

    /// The static look (cx-sya4n) turns a blink or pulse into the steady ring: the ring then
    /// rests at the steady strength the swell ends on, so it does not snap down to the faint
    /// rest when the animation is removed.
    @Test func staticLookRestsWhereItsSteadySwellEnds() {
        let design = DesignSettings.shared
        let before = design.statusIndicator
        Motion.reduceMotionOverride = false
        defer {
            design.statusIndicator = before
            Motion.reduceMotionOverride = nil
        }
        design.statusIndicator.animation = .static
        for style in [AttentionStyle.blink, .pulse] {
            var settings = AttentionSettings()
            settings.style = style
            let rest = Motion.attentionRestingOpacity(settings, look: .subtle)
            #expect(rest == AttentionHighlightLook.subtle.steadyOpacity, "\(style) rests at \(rest)")
            let values = opacities(Motion.indicators.attentionAnimation(settings, look: .subtle))
            #expect(values.last == rest, "\(style) swell ends at \(String(describing: values.last)), rests at \(rest)")
        }
    }
}
