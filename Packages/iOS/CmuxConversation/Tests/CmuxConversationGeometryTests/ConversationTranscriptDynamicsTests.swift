import CmuxConversationGeometry
import CoreGraphics
import Foundation
import Testing

/// ChatKit's transcript dynamics (`CKTranscriptCompositionalLayout`, iOS
/// 26.5 runtime): rows trail the scroll by a share that depends on their
/// distance from the finger, closing the gap a little each displayed frame.
@Suite struct ConversationTranscriptDynamicsTests {
    /// At 60 Hz a row closes `1 - easing` of the gap per frame; a 120 Hz frame
    /// closes the share that two of them would compound to over 1/60 s
    /// (ChatKit: `(1 - e) * (1 - (1 - e)^(dt * 60)) / e`, at most 1).
    @Test func stepSumsSixtyHertzFramesOverTheFrameLength() {
        let sixtyHertzStep = ConversationTranscriptDynamics.step(easing: 0.25, duration: 1.0 / 60)
        #expect(abs(sixtyHertzStep - 0.75) < 1e-12)
        let e = 0.25, n = 0.5
        let expected = (1 - e) * (1 - pow(1 - e, n)) / e
        let oneTwentyHertzStep = ConversationTranscriptDynamics.step(easing: e, duration: 1.0 / 120)
        #expect(abs(oneTwentyHertzStep - expected) < 1e-12)
        // Rigid when there is no easing, and never past the target.
        #expect(ConversationTranscriptDynamics.step(easing: 0, duration: 1.0 / 120) == 1)
        #expect(ConversationTranscriptDynamics.step(easing: 0.01, duration: 1.0 / 20) == 1)
    }

    /// Rows keep a base easing at the finger (incoming 0.01, outgoing 0.005,
    /// centered 0) and add up to 0.75 a viewport away, `1 - (1 - t)^3`,
    /// averaged over the row's top, center and bottom.
    @Test func anchorEasingGrowsWithDistanceFromTheFinger() {
        let base = ConversationTranscriptDynamics.baseEasing(.incoming)
        #expect(base == 0.01)
        #expect(ConversationTranscriptDynamics.baseEasing(.outgoing) == 0.005)
        #expect(ConversationTranscriptDynamics.baseEasing(.centered) == 0)
        let atFinger = ConversationTranscriptDynamics.anchorEasing(base: base, centerDistance: 0, height: 0, viewport: 900)
        #expect(abs(atFinger - base) < 1e-12)
        let far = ConversationTranscriptDynamics.anchorEasing(base: base, centerDistance: 2000, height: 40, viewport: 900)
        #expect(abs(far - (base + 0.75)) < 1e-12)
        let half = ConversationTranscriptDynamics.anchorEasing(base: base, centerDistance: 450, height: 0, viewport: 900)
        #expect(abs(half - (base + 0.75 * (1 - pow(0.5, 3)))) < 1e-12)
        // A tall row averages its top, center and bottom.
        let tall = ConversationTranscriptDynamics.anchorEasing(base: 0, centerDistance: 300, height: 200, viewport: 900)
        let parts: [Double] = [200.0, 300.0, 400.0].map { (d: Double) -> Double in 0.75 * (1 - pow(1 - d / 900, 3)) }
        #expect(abs(tall - parts.reduce(0, +) / 3) < 1e-12)
    }

    /// A fling's target spreads rows past the first viewport a little further
    /// (`base + 0.75 + 0.15 t^3`); rows within it keep their easing.
    @Test func flingEasingTrailsFarRowsFurther() {
        let range = ConversationTranscriptDynamics.flingRange(anchorY: 3000, targetOffsetY: 1000, viewport: 900)
        #expect(range == 1100)
        #expect(ConversationTranscriptDynamics.flingRange(anchorY: 3000, targetOffsetY: 2500, viewport: 900) == 450)
        #expect(ConversationTranscriptDynamics.flingRange(anchorY: 1000, targetOffsetY: 2600, viewport: 900) == 1600)
        #expect(ConversationTranscriptDynamics.flingEasing(base: 0.01, centerDistance: 800, height: 40, viewport: 900, range: range) == nil)
        let edge = ConversationTranscriptDynamics.flingEasing(base: 0.01, centerDistance: 901, height: 0, viewport: 900, range: range)
        #expect(abs((edge ?? 0) - (0.76 + 0.15 * pow(1.0 / 1100, 3))) < 1e-9)
        let farthest = ConversationTranscriptDynamics.flingEasing(base: 0.01, centerDistance: 5000, height: 0, viewport: 900, range: range)
        #expect(abs((farthest ?? 0) - 0.91) < 1e-12)
    }

    /// A row steps toward its place each frame and snaps home within a
    /// quarter pixel.
    @Test func advanceSnapsWithinAQuarterPixel() {
        let moved = ConversationTranscriptDynamics.advance(current: 10, target: 0, easing: 0.5, duration: 1.0 / 60, scale: 3)
        #expect(moved == 5)
        let home = ConversationTranscriptDynamics.advance(current: 0.15, target: 0, easing: 0.5, duration: 1.0 / 60, scale: 3)
        #expect(home == 0)
        let held = ConversationTranscriptDynamics.advance(current: 0.2, target: 0, easing: 0.5, duration: 1.0 / 60, scale: 3)
        #expect(held == 0.1)
    }
}
