import QuartzCore
@testable import CmuxNextDesign
import Testing

/// The opt-in steady ring (the default style is no ring) is clearly visible and arrives with
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
        let animation = try #require(Motion.attentionAnimation(steady, look: .subtle))
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

    @Test func reduceMotionFadesInWithoutAPulse() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let values = opacities(Motion.attentionAnimation(steady, look: .subtle))
        let rest = Motion.attentionRestingOpacity(steady, look: .subtle)
        #expect(values == [0, rest])
    }

    @Test func aFurtherNotificationSwellsWithoutDroppingOut() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let rest = Motion.attentionRestingOpacity(steady, look: .subtle)
        let values = opacities(Motion.attentionAnimation(steady, look: .subtle, showing: true))
        #expect(values.first == rest)
        #expect((values.min() ?? 0) >= rest, "the ring dropped out: \(values)")
        #expect((values.max() ?? 0) > rest)
    }
}
