import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// REOPEN-F2 follow-up (Performance Lead, 2026-11-02): a window the launch restores opens in place with no
/// animation (RestoredWindowOpensInPlaceTests), and a window made AFTER the restore opens with AppKit's
/// document-window zoom only when the panes motion gate allows movement, never when it does not.
@MainActor @Suite struct WindowOpenBehaviorTests {
    private func policy(enabled: Bool = true, disabled: Set<MotionCategory> = [], reduceMotion: Bool = false,
                        speed: MotionSpeed = .fast, liveResize: Bool = false) -> MotionPolicy {
        MotionPolicy(speed: speed, reduceMotion: reduceMotion, enabledKinds: [], liveResize: liveResize,
                     animationsEnabled: enabled, disabledCategories: disabled).for(.panes)
    }

    @Test func aWindowMadeAfterTheRestoreZoomsInWhenMovementAnimates() {
        #expect(policy().windowOpenBehavior(restoring: false) == .documentWindow)
    }

    @Test func aWindowMadeAfterTheRestoreOpensInPlaceWhenThePanesGateStopsMovement() {
        let still: [(String, MotionPolicy)] = [
            ("master switch off", policy(enabled: false)),
            ("panes animations off", policy(disabled: [.panes])),
            ("Reduce Motion", policy(reduceMotion: true)),
            ("speed off", policy(speed: .off)),
        ]
        for (why, policy) in still {
            #expect(!policy.animatesMovement, "\(why): the policy still moves")
            #expect(policy.windowOpenBehavior(restoring: false) == .none, "\(why): a new window still zooms in")
        }
    }

    @Test func aRestoredWindowNeverAnimatesEvenWithMotionOn() {
        #expect(policy().animatesMovement)
        #expect(policy().windowOpenBehavior(restoring: true) == .none)
    }

    /// The live gate follows the policy: Reduce Motion (the override) turns the zoom off, and back on.
    @Test func theLiveGateFollowsReduceMotion() {
        let previous = Motion.reduceMotionOverride
        defer { Motion.reduceMotionOverride = previous }
        Motion.reduceMotionOverride = true
        #expect(Motion.panes.windowOpenBehavior(restoring: false) == .none)
        Motion.reduceMotionOverride = false
        #expect(Motion.panes.windowOpenBehavior(restoring: false) == (Motion.panes.animatesMovement ? .documentWindow : .none))
        #expect(Motion.panes.windowOpenBehavior(restoring: true) == .none)
    }
}
