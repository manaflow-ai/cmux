/// A machine-readable sudo-broker failure reason.
public enum SudoResultErrorCode: String, Codable, Sendable, Equatable {
    /// Touch ID is not enabled in the local sudo PAM policy.
    case pamTidUnavailable = "pam_tid_unavailable"

    /// The request expired before approval.
    case approvalTimedOut = "approval_timed_out"

    /// The generation-qualified requesting process exited before approval.
    case requesterUnavailable = "requester_unavailable"

    /// An approved execution exceeded its independent watchdog.
    case executionTimedOut = "execution_timed_out"

    /// An approved execution was interrupted before a terminal result existed.
    case executionInterrupted = "execution_interrupted"

    /// The approved script could not be staged safely.
    case stagingFailed = "staging_failed"

    /// The independent execution runner could not be launched.
    case runnerLaunchFailed = "runner_launch_failed"

    /// Sudo exited because Touch ID was cancelled or authentication was unavailable.
    case authenticationFailed = "authentication_failed"

    /// The approved command could not be spawned by the independent runner.
    case processLaunchFailed = "process_launch_failed"

    /// One or more privileged descendants survived bounded process-tree cleanup.
    case processCleanupFailed = "process_cleanup_failed"

    /// LaunchServices could not open the exact enclosing cmux app bundle.
    case appLaunchFailed = "app_launch_failed"

    /// The CLI could not monitor the durable result stream safely.
    case resultWaitFailed = "result_wait_failed"
}
