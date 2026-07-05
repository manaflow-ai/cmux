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

    @Test func trustFailurePreservesEarlierSuccessesWhenProvided() {
        let checklist = MobilePairingChecklist.inProgress.applyingFailure(
            .trust,
            message: "This Mac is not trusted.",
            guidance: "Approve the device on your Mac.",
            succeededSteps: [.network, .authentication]
        )

        #expect(checklist.network.status == .succeeded)
        #expect(checklist.authentication.status == .succeeded)
        #expect(checklist.trust.status == .failed)
        #expect(checklist.trust.message == "This Mac is not trusted.")
        #expect(checklist.trust.guidance == "Approve the device on your Mac.")
        #expect(checklist.hasFailure)
    }

    @Test func trustFailureWithoutKnownSuccessesResetsEarlierStepsToPending() {
        let checklist = MobilePairingChecklist.inProgress.applyingFailure(
            .trust,
            message: "This Mac is not trusted."
        )

        #expect(checklist.network.status == .pending)
        #expect(checklist.authentication.status == .pending)
        #expect(checklist.trust.status == .failed)
        #expect(checklist.trust.message == "This Mac is not trusted.")
        #expect(checklist.hasFailure)
    }
}
