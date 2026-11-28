@testable import CmuxNextAgentPermissions
import Testing

/// Computer use onboarding (agent-permissions-DESIGN.md section 6): one
/// question per step, derived from the grants, so a revoked grant sends the
/// flow back to its step and a grant given elsewhere skips its step.
@Suite struct ComputerUseOnboardingFlowTests {
    @Test func withoutASignedHelperOnlyTheUnavailableStepShows() {
        let flow = ComputerUseOnboardingFlow(helperAvailable: false, introSeen: true, accessibility: true, screenRecording: true)
        #expect(flow.step == .unavailable)
        #expect(flow.progress == nil)
    }

    @Test func theStepsGoInOrderOneActionEach() {
        var flow = ComputerUseOnboardingFlow(helperAvailable: true)
        #expect(flow.step == .intro)
        flow.introSeen = true
        #expect(flow.step == .accessibility)
        #expect(flow.step.grant == .accessibility)
        flow.apply(accessibility: true, screenRecording: false)
        #expect(flow.step == .screenRecording)
        flow.apply(accessibility: true, screenRecording: true)
        #expect(flow.step == .tryIt)
        flow.recordTrial(passed: true)
        #expect(flow.step == .howToStop)
        #expect(flow.progress == 4)
    }

    @Test func aGrantGivenElsewhereSkipsItsStep() {
        var flow = ComputerUseOnboardingFlow(helperAvailable: true, introSeen: true)
        flow.apply(accessibility: false, screenRecording: true)
        #expect(flow.step == .accessibility)
        flow.apply(accessibility: true, screenRecording: true)
        #expect(flow.step == .tryIt)
    }

    @Test func aRevokedGrantGoesBackToItsStepAndClearsTheTrial() {
        var flow = ComputerUseOnboardingFlow(helperAvailable: true, introSeen: true, accessibility: true, screenRecording: true,
                                             trialPassed: true)
        #expect(flow.step == .howToStop)
        flow.apply(accessibility: true, screenRecording: false)
        #expect(flow.step == .screenRecording)
        #expect(!flow.trialPassed)
        flow.apply(accessibility: true, screenRecording: true)
        #expect(flow.step == .tryIt, "the person retries the test click with the grants they have now")
    }

    @Test func aFailedTrialOffersRetryAndNamesTheMissingGrant() {
        var flow = ComputerUseOnboardingFlow(helperAvailable: true, introSeen: true, accessibility: true, screenRecording: true)
        flow.recordTrial(passed: false)
        #expect(flow.step == .tryIt)
        #expect(flow.trialFailed)
        #expect(flow.missingGrant == nil, "both grants on: the failure is a retry, not a grant")
        flow.recordTrial(passed: true)
        #expect(flow.step == .howToStop)
    }
}
