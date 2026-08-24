#if os(iOS)
import Testing

@testable import CmuxMobileShellUI

/// Behavior tests for the welcome tour's stage pipeline policy.
@Suite struct WelcomeStagePlanTests {
    @Test func fullPipelineWhenNothingIsResolved() {
        let plan = WelcomeStagePlan(isAuthenticated: false, needsNotificationDecision: true)
        #expect(plan.stages == [.hello, .notifications, .signIn, .connect])
    }

    @Test func authenticatedUserSkipsSignIn() {
        let plan = WelcomeStagePlan(isAuthenticated: true, needsNotificationDecision: true)
        #expect(plan.stages == [.hello, .notifications, .connect])
    }

    @Test func decidedNotificationsSkipTheOptIn() {
        let plan = WelcomeStagePlan(isAuthenticated: false, needsNotificationDecision: false)
        #expect(plan.stages == [.hello, .signIn, .connect])
    }

    @Test func everythingResolvedLeavesDemoAndConnect() {
        let plan = WelcomeStagePlan(isAuthenticated: true, needsNotificationDecision: false)
        #expect(plan.stages == [.hello, .connect])
    }

    @Test func nextAndPreviousWalkThePlanInOrder() {
        let plan = WelcomeStagePlan(isAuthenticated: false, needsNotificationDecision: true)
        #expect(plan.next(after: .hello) == .notifications)
        #expect(plan.next(after: .notifications) == .signIn)
        #expect(plan.next(after: .signIn) == .connect)
        #expect(plan.next(after: .connect) == nil)
        #expect(plan.previous(before: .connect) == .signIn)
        #expect(plan.previous(before: .hello) == nil)
    }

    @Test func signInCompletionOnScreenResolvesForwardToConnect() {
        let plan = WelcomeStagePlan(isAuthenticated: true, needsNotificationDecision: false)
        #expect(plan.resolved(.signIn) == .connect)
    }

    @Test func advancingFromAJustDroppedStageDoesNotSkipItsSuccessor() {
        // The notification decision resolved while its stage was on screen:
        // advancing from it must land on sign-in, not skip to connect.
        let plan = WelcomeStagePlan(isAuthenticated: false, needsNotificationDecision: false)
        #expect(plan.next(after: .notifications) == .signIn)
    }

    @Test func notificationDecisionOnScreenResolvesForward() {
        let plan = WelcomeStagePlan(isAuthenticated: false, needsNotificationDecision: false)
        #expect(plan.resolved(.notifications) == .signIn)
    }

    @Test func positionDrivesProgressDots() {
        let plan = WelcomeStagePlan(isAuthenticated: true, needsNotificationDecision: true)
        #expect(plan.position(of: .hello) == 0)
        #expect(plan.position(of: .notifications) == 1)
        #expect(plan.position(of: .connect) == 2)
        // A dropped stage reports its resolved stage's position.
        #expect(plan.position(of: .signIn) == 2)
    }
}
#endif
