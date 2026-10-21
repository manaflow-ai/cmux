import QuartzCore
@testable import CmuxNextDesign
import Testing

/// cmux classic flashes a pane's ring when its notification is dismissed by going into the
/// pane; the ring itself appears steady (Austin, 2026-10-20: "the blinking should happen when we
/// switch focus to that pane and it dismisses").
@MainActor @Suite(.serialized) struct AttentionDismissFlashTests {
    private func opacities(_ animation: CAAnimation?) -> [Float] {
        ((animation as? CAKeyframeAnimation)?.values ?? []).compactMap { ($0 as? NSNumber)?.floatValue }
    }

    @Test func theDismissBlinksThenLeavesNoRing() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let settings = AttentionSettings()
        let values = opacities(try #require(Motion.indicators.attentionDismissAnimation(settings, look: .subtle), "no dismiss flash"))
        #expect(values.last == 0, "the ring stays after the flash: \(values)")
        let blinks = zip(values, values.dropFirst()).filter { $0 > 0 && $1 == 0 }.count
        #expect(blinks == settings.blinkCount, "\(blinks) blinks, want \(settings.blinkCount): \(values)")
    }

    @Test func noRingStyleHasNoDismissFlash() {
        var settings = AttentionSettings()
        settings.style = .none
        #expect(Motion.indicators.attentionDismissAnimation(settings, look: .subtle) == nil)
    }
}
