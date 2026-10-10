import Testing
@testable import CmuxNextDesign

/// The shared indicator config follows the Reduce Motion test override when
/// the override is set after the appearance exists (CI, 2026-10-02: on a
/// runner with Reduce Motion on, an appearance an earlier test created kept
/// "no loops", and the sidebar row spinner never started).
@MainActor @Suite struct StatusIndicatorAppearanceTests {
    @Test func aLaterReduceMotionOverrideReachesTheConfigAtOnce() {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = true
        let appearance = StatusIndicatorAppearance()
        #expect(!appearance.config.animatesLoops)
        Motion.reduceMotionOverride = false
        #expect(appearance.config.animatesLoops == (Motion.speed != .off))
    }
}
