import Testing
@testable import CmuxMobileShellModel

@Suite struct MobilePairingChecklistTests {
    @Test func inProgressMarksEveryStepChecking() {
        let checklist = MobilePairingChecklist.inProgress

        #expect(checklist.network.status == .inProgress)
        #expect(checklist.authentication.status == .inProgress)
        #expect(checklist.trust.status == .inProgress)
        #expect(checklist.hasFailure == false)
    }

    @Test func networkFailureLeavesLaterStepsPending() {
        let checklist = MobilePairingChecklist.inProgress.applyingFailure(
            .network,
            message: "Connect to Wi-Fi."
        )

        #expect(checklist.network.status == .failed)
        #expect(checklist.network.message == "Connect to Wi-Fi.")
        #expect(checklist.authentication.status == .pending)
        #expect(checklist.trust.status == .pending)
        #expect(checklist.hasFailure)
    }

    @Test func authenticationFailureCanPreserveKnownNetworkSuccess() {
        let checklist = MobilePairingChecklist.inProgress.applyingFailure(
            .authentication,
            message: "Use the same account.",
            guidance: "Sign in again.",
            succeededSteps: [.network]
        )

        #expect(checklist.network.status == .succeeded)
        #expect(checklist.authentication.status == .failed)
        #expect(checklist.authentication.message == "Use the same account.")
        #expect(checklist.authentication.guidance == "Sign in again.")
        #expect(checklist.trust.status == .pending)
    }

    @Test func succeededMarksEveryStepVerified() {
        let checklist = MobilePairingChecklist.succeeded

        #expect(checklist.steps.map(\.status) == [.succeeded, .succeeded, .succeeded])
        #expect(checklist.hasFailure == false)
    }
}
