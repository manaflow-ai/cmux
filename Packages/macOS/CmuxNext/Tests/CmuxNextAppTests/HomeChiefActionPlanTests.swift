import CmuxHomeCore
@testable import CmuxNextApp
import Testing
import CmuxNextHomeEngine

/// Audit rows 33-34 (unimpl-audit-actions.md): `home.toggleChiefSettings` and `home.stopChief` only
/// posted a notification to a Home in front, so from the palette or `cmux action run` with no Home
/// in front they did nothing and said nothing. They now act on the Chief directly (Stop) or bring
/// Home forward (Settings), and refuse with a reason only when there is nothing to act on.
struct HomeChiefActionPlanTests {
    private let defaultChief = ConversationID("conv_default")
    private let otherChief = ConversationID("conv_other")

    private func plan(_ front: HomeChiefActionPlan.Front, working: Set<ConversationID> = []) -> HomeChiefActionPlan {
        HomeChiefActionPlan(front: front, chiefs: [
            .init(conversation: otherChief, isWorking: working.contains(otherChief), isDefault: false),
            .init(conversation: defaultChief, isWorking: working.contains(defaultChief), isDefault: true),
        ])
    }

    @Test func aWorkingHomeInFrontStopsItsOwnChief() {
        #expect(plan(.chief(isWorking: true), working: [otherChief]).stop == .front)
    }

    @Test func anIdleHomeInFrontNeverStopsAnotherChief() {
        #expect(plan(.chief(isWorking: false), working: [otherChief]).stop == .nothingRuns)
    }

    @Test func withNoHomeInFrontTheWorkingChiefStopsDefaultFirst() {
        #expect(plan(.none, working: [otherChief]).stop == .chief(otherChief))
        #expect(plan(.none, working: [otherChief, defaultChief]).stop == .chief(defaultChief))
    }

    @Test func withNothingRunningStopIsRefused() {
        #expect(plan(.none).stop == .nothingRuns)
        #expect(HomeChiefActionPlan(front: .none, chiefs: []).stop == .nothingRuns)
    }

    @Test func settingsToggleOnTheHomeInFrontElseOpenTheDefaultChief() {
        #expect(plan(.chief(isWorking: false)).settings == .front)
        #expect(plan(.none).settings == .open(defaultChief))
        let onlyOther = HomeChiefActionPlan(front: .none, chiefs: [.init(conversation: otherChief, isWorking: false, isDefault: false)])
        #expect(onlyOther.settings == .open(otherChief))
    }

    @Test func settingsWithNoChiefAreRefused() {
        #expect(HomeChiefActionPlan(front: .none, chiefs: []).settings == .noChief)
    }
}
