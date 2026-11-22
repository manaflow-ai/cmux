import QuartzCore
import Testing
@testable import CmuxNextDesign

/// The attention ring animation follows `notifications.attention.*`.
@MainActor
struct AttentionMotionTests {
    @Test func restingOpacityFollowsPersistAndStyle() {
        var settings = AttentionSettings()
        #expect(Motion.attentionRestingOpacity(settings) == 1)
        settings.persists = false
        #expect(Motion.attentionRestingOpacity(settings) == 0)
        settings.persists = true
        settings.style = .none
        #expect(Motion.attentionRestingOpacity(settings) == 0)
        #expect(Motion.attentionAnimation(settings) == nil)
    }

    @Test func blinkRunsTheConfiguredCountAndPulseItsDuration() throws {
        guard Motion.animatesLoops else { return }
        var settings = AttentionSettings()
        settings.style = .blink
        settings.blinkCount = 3
        let blink = try #require(Motion.attentionAnimation(settings) as? CAKeyframeAnimation)
        #expect(blink.values?.count == 7)
        #expect((blink.values?.last as? Float) == 1)
        settings.style = .pulse
        settings.duration = 4
        let pulse = try #require(Motion.attentionAnimation(settings) as? CABasicAnimation)
        #expect(pulse.repeatDuration == 4)
        #expect(pulse.repeatCount == 0)
    }
}
