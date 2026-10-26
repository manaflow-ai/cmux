import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeups
import QuartzCore
import Testing

/// Looping indicators ask the render server for only the frames they need while
/// `DesignSettings.loopsFollowFrameRate` (feature `frameRateClasses`, p03-rendering-013), and never change
/// their timing for it.
@MainActor @Suite(.serialized) struct LoopFrameRateTests {
    private func loops() throws -> [(String, CAAnimation)] {
        let gate = Motion.indicators
        return [
            ("spin", try #require(gate.spinAnimation())),
            ("sweep", try #require(gate.sweepAnimation(segment: 10, travel: 100))),
            ("breath", try #require(gate.breathAnimation(low: 0.4))),
            ("pulse", try #require(gate.pulseAnimation(low: 0.3))),
        ]
    }

    @Test func onLoopsAskFor30HzWithTheSameTiming() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil; DesignSettings.shared.loopsFollowFrameRate = false }
        let before = try loops().map { ($0.0, $0.1.duration, $0.1.repeatCount) }
        DesignSettings.shared.loopsFollowFrameRate = true
        let after = try loops()
        for ((name, duration, repeats), (_, loop)) in zip(before, after) {
            #expect(loop.preferredFrameRateRange.maximum == 30, "\(name) asks for \(loop.preferredFrameRateRange.maximum) Hz")
            #expect(loop.duration == duration && loop.repeatCount == repeats, "\(name)'s timing changed")
        }
        let spinner = try #require(Motion.indicators.period(.spinner))
        let steps = try #require(Motion.indicators.stepAnimation(steps: 8))
        #expect(steps.preferredFrameRateRange.minimum == FrameRate.stepping(8, every: spinner).hertz)
        #expect(steps.preferredFrameRateRange.maximum <= 30)
    }

    /// The decision is the policy's: an injected policy paces a loop, whatever the shared settings say.
    @Test func anInjectedPolicyPacesTheSweep() throws {
        var policy = MotionPolicy(speed: .fast, reduceMotion: false, pacesLoops: true)
        let paced = try #require(Motion.indicators.sweepAnimation(segment: 10, travel: 100, policy: policy))
        #expect(paced.preferredFrameRateRange.maximum == 30)
        policy.pacesLoops = false
        let plain = try #require(Motion.indicators.sweepAnimation(segment: 10, travel: 100, policy: policy))
        #expect(plain.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum)
        #expect(plain.duration == paced.duration)
    }

    @Test func offLoopsKeepTheDefaultRange() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        DesignSettings.shared.loopsFollowFrameRate = false
        for (name, loop) in try loops() {
            #expect(loop.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum, "\(name) asked for a rate")
        }
    }
}
