@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// Leo 2026-10-20: "animations all around are a bit slow". Every animation keeps to one short
/// scale (schemas/motion-scale/motion-scale.json, `MotionScale`): quick 80 ms, micro 120 ms,
/// standard 180 ms, large 240 ms, the ceiling. Every timed fade is a step (or instant), and every
/// spring ends visibly (within 0.5% of its travel, `SpringParameters.perceivedDuration`) by the
/// ceiling. These read the code defaults, not a Debug Settings override.
@MainActor @Suite struct MotionScaleTests {
    /// Long ambient fades, not transitions: nothing waits on them and nothing reads them as slow.
    static let ambientFades: [MotionFade: String] = [
        .highlight: "a found Settings row's highlight fading out over a reading pause",
        .hibernateRing: "a hibernated tab's dotted ring fading in (Chromium TabIcon, 1 s)",
        .focusFlash: "the ring flashed where focus moved without a click, fading out slowly enough to be seen",
    ]

    static func onScale(_ seconds: TimeInterval) -> Bool {
        seconds == 0 || MotionScale.steps.contains { abs($0 - seconds) < 1e-9 }
    }

    @Test func theScaleIsSortedAndEndsAtTheCeiling() {
        #expect(MotionScale.steps == MotionScale.steps.sorted())
        #expect(Set(MotionScale.steps).count == MotionScale.steps.count, "a step repeats")
        #expect(MotionScale.steps == [MotionScale.quick, MotionScale.micro, MotionScale.standard, MotionScale.large])
        #expect(MotionScale.ceiling == MotionScale.large)
        #expect(MotionScale.steps.last == MotionScale.ceiling)
    }

    @Test(arguments: MotionFade.allCases)
    func everyFadeIsAStepOfTheScale(_ fade: MotionFade) throws {
        let seconds = try #require(MotionTunables.fadeDefaults[fade]?.0, "\(fade) has no default")
        if let reason = Self.ambientFades[fade] {
            #expect(seconds > MotionScale.ceiling, "\(fade) is listed as ambient (\(reason)) but is a transition now")
            return
        }
        #expect(Self.onScale(seconds), "\(fade) fades over \(seconds) s, not a step of \(MotionScale.steps)")
    }

    @Test(arguments: MotionSpring.allCases)
    func everySpringEndsVisiblyByTheCeiling(_ spring: MotionSpring) throws {
        let parameters = try #require(MotionTunables.springDefaults[spring]?.0, "\(spring) has no default")
        let end = parameters.perceivedDuration
        #expect(end > 0)
        #expect(end <= MotionScale.ceiling, "\(spring) (\(parameters.response) / \(parameters.dampingFraction)) ends visibly at \(Int(end * 1000)) ms, past \(Int(MotionScale.ceiling * 1000)) ms")
    }

    /// Reduce Motion caps every fade at one crossfade, the shortest step.
    @Test func theReduceMotionCeilingIsQuick() throws {
        #expect(try #require(MotionTunables.fadeDefaults[.crossfade]?.0) == MotionScale.quick)
    }

    /// The other one-off transition defaults in the Motion directory keep to the scale too.
    @Test func otherTimedTransitionsAreOnTheScale() {
        #expect(Self.onScale(MotionTunables.agentCursorGlideMax.defaultValue), "agent cursor glide limit")
        #expect(Self.onScale(Motion.steadyPulseDuration), "attention ring arrival swell")
    }
}
