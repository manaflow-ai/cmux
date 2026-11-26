@testable import CmuxSudoBroker

extension SudoFailureMessages {
    static let testMessages = SudoFailureMessages(
        pamTidUnavailable: "pam_tid unavailable; run scripts/setup-pam-tid.sh",
        approvalTimedOut: "approval timed out",
        requesterUnavailable: "requester unavailable",
        executionInterrupted: "execution interrupted",
        executionTimedOut: "execution timed out",
        authenticationFailed: "authentication failed",
        stagingFailed: "staging failed",
        runnerLaunchFailed: "runner launch failed",
        processLaunchFailed: "process launch failed",
        cleanupFailed: "cleanup failed"
    )
}
