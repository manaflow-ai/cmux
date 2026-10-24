import QuartzCore
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

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

    private func controlPoints(_ curve: CAMediaTimingFunction) -> [Float] {
        (1...2).flatMap { index -> [Float] in
            var point = [Float](repeating: 0, count: 2)
            curve.getControlPoint(at: index, values: &point)
            return point
        }
    }

    /// Unread rings from classic (Lawrence, 2026-10-20): the dismiss flash is classic's
    /// `FocusFlashPattern.doubleBlink` (origin/main `Sources/Panels/Panel.swift`): opacity 0, 1, 0,
    /// 1, 0 at even key times, ease-out rises and ease-in falls, at full strength. Classic ran it in
    /// 0.9 s; the 2 Hz cap holds it at one `flash` loop period (1 s or more).
    @Test func theDismissIsClassicsDoubleBlink() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let animation = try #require(Motion.indicators.attentionDismissAnimation(AttentionSettings(), look: .subtle))
        let flash = try #require(animation as? CAKeyframeAnimation, "the dismiss is not one keyframe flash")
        #expect(opacities(flash) == [0, 1, 0, 1, 0])
        #expect(flash.keyTimes?.map(\.doubleValue) == [0, 0.25, 0.5, 0.75, 1])
        let rise = controlPoints(CAMediaTimingFunction(name: .easeOut)), fall = controlPoints(CAMediaTimingFunction(name: .easeIn))
        #expect((flash.timingFunctions ?? []).map(controlPoints) == [rise, fall, rise, fall])
        #expect(flash.duration >= 0.9, "faster than classic: \(flash.duration) s")
        #expect(flash.duration >= MotionLoop.flash.period - 1e-9, "faster than the 2 Hz cap: \(flash.duration) s")
    }

    /// Reduce Motion: no flash; the ring just goes.
    @Test func reduceMotionHasNoDismissFlash() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        #expect(Motion.indicators.attentionDismissAnimation(AttentionSettings(), look: .subtle) == nil)
    }
}
