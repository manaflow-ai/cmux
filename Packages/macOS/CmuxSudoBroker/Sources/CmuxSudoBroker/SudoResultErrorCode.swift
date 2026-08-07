/// A machine-readable sudo-broker failure reason.
public enum SudoResultErrorCode: String, Codable, Sendable, Equatable {
    /// Touch ID is not enabled in the local sudo PAM policy.
    case pamTidUnavailable = "pam_tid_unavailable"

    /// The request expired before approval.
    case approvalTimedOut = "approval_timed_out"

    /// An approved execution exceeded its independent watchdog.
    case executionTimedOut = "execution_timed_out"

    /// An approved execution was interrupted before a terminal result existed.
    case executionInterrupted = "execution_interrupted"

    /// The approved script could not be staged safely.
    case stagingFailed = "staging_failed"

    /// The independent execution runner could not be launched.
    case runnerLaunchFailed = "runner_launch_failed"
}

