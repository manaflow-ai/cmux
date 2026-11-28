import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// POLISH audit, batch 3 (cx-2grmt): Home's header band appeared and left in one frame under
/// Reduce Motion (its fade was turned off there). Reduce Motion keeps fades, at the crossfade
/// length (motion.md rule 7).
@MainActor @Suite(.serialized) struct HomeHeaderFadeTests {
    @Test func theHeaderBandFadesUnderReduceMotion() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        for shown in [true, false] {
            let seconds = HomeNativeTranscriptView.headerFadeDuration(shown: shown)
            #expect(seconds > 0, "shown: \(shown)")
            #expect(seconds <= Motion.duration(.crossfade))
        }
    }
}
