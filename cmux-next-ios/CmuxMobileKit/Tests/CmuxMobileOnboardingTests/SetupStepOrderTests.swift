#if os(iOS)
import Testing
@testable import CmuxMobileOnboarding

/// Setup's plan is fixed once the team list loads, which can be after the
/// user has left a page it drops. The fleet's iOS push probe tapped Connect
/// your Mac's button on such a page, and setup ended there: the notifications
/// step never showed, so the phone was never asked and never registered for
/// push.
@Suite struct SetupStepOrderTests {
    @Test func followsThePlan() {
        let plan: [SetupFlow.Step] = [.team, .pairMac, .notifications]
        #expect(SetupFlow.step(after: .team, in: plan) == .pairMac)
        #expect(SetupFlow.step(after: .pairMac, in: plan) == .notifications)
        #expect(SetupFlow.step(after: .notifications, in: plan) == nil)
        #expect(SetupFlow.step(after: .createTeam, in: plan) == .pairMac)
    }

    @Test func aPageThePlanDroppedStillLeadsOn() {
        #expect(SetupFlow.step(after: .pairMac, in: [.team, .notifications]) == .notifications)
        #expect(SetupFlow.step(after: .team, in: [.notifications]) == .notifications)
        #expect(SetupFlow.step(after: .pairMac, in: [.team]) == nil)
        #expect(SetupFlow.step(after: .pairMac, in: []) == nil)
    }
}
#endif
