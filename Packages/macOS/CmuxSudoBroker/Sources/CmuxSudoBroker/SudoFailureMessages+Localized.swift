import Foundation

extension SudoFailureMessages {
    /// Localized production diagnostics shared by the app, CLI, and hidden runner.
    public static var localized: SudoFailureMessages {
        SudoFailureMessages(
            pamTidUnavailable: String(
                localized: "sudo.error.pam_tid_unavailable",
                defaultValue: "Touch ID for sudo is not configured. Run cmux sudo setup-touch-id."
            ),
            approvalTimedOut: String(
                localized: "sudo.error.approval_timeout",
                defaultValue: "sudo request expired before approval"
            ),
            requesterUnavailable: String(
                localized: "sudo.error.requester_unavailable",
                defaultValue: "sudo request cancelled because the requesting process exited"
            ),
            executionInterrupted: String(
                localized: "sudo.error.execution_interrupted",
                defaultValue: "approved sudo execution was interrupted before a result was written"
            ),
            executionTimedOut: String(
                localized: "sudo.error.execution_timeout",
                defaultValue: "approved sudo execution timed out; the process tree was terminated"
            ),
            authenticationFailed: String(
                localized: "sudo.error.authentication_failed",
                defaultValue: "sudo could not authenticate: Touch ID was cancelled or unavailable"
            ),
            stagingFailed: String(
                localized: "sudo.error.staging_failed",
                defaultValue: "the approved sudo script could not be staged safely"
            ),
            runnerLaunchFailed: String(
                localized: "sudo.error.runner_launch_failed",
                defaultValue: "the independent sudo runner could not be launched"
            ),
            processLaunchFailed: String(
                localized: "sudo.error.process_launch_failed",
                defaultValue: "the approved sudo command could not be launched"
            ),
            cleanupFailed: String(
                localized: "sudo.error.cleanup_failed",
                defaultValue: "sudo could not finish process cleanup; one or more processes survived"
            )
        )
    }
}
