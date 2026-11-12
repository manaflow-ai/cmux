/// Localized diagnostics persisted when the broker fails a request.
public struct SudoFailureMessages: Sendable, Equatable {
    /// Guidance shown when Touch ID is absent from sudo's PAM policy.
    public let pamTidUnavailable: String

    /// The diagnostic for a request that expired before approval.
    public let approvalTimedOut: String

    /// The diagnostic for a requesting process that exited before approval.
    public let requesterUnavailable: String

    /// The diagnostic for an interrupted approved execution.
    public let executionInterrupted: String

    /// The diagnostic for an approved execution that exceeded its deadline.
    public let executionTimedOut: String

    /// The diagnostic for sudo authentication that did not complete successfully.
    public let authenticationFailed: String

    /// The diagnostic for an approved script that could not be staged safely.
    public let stagingFailed: String

    /// The diagnostic for an independent runner that could not be launched.
    public let runnerLaunchFailed: String

    /// The diagnostic for an approved sudo command that could not be spawned.
    public let processLaunchFailed: String

    /// The diagnostic for a process tree that could not be fully terminated.
    public let cleanupFailed: String

    /// Creates the localized broker failure messages.
    ///
    /// - Parameters:
    ///   - pamTidUnavailable: Guidance for a missing Touch ID PAM rule.
    ///   - approvalTimedOut: The approval deadline diagnostic.
    ///   - requesterUnavailable: The requester-liveness diagnostic.
    ///   - executionInterrupted: The interrupted-execution diagnostic.
    ///   - executionTimedOut: The bounded execution deadline diagnostic.
    ///   - authenticationFailed: The Touch ID authentication diagnostic.
    ///   - stagingFailed: The approved-script staging diagnostic.
    ///   - runnerLaunchFailed: The independent-runner launch diagnostic.
    ///   - processLaunchFailed: The approved-command spawn diagnostic.
    ///   - cleanupFailed: The incomplete process-tree cleanup diagnostic.
    public init(
        pamTidUnavailable: String,
        approvalTimedOut: String,
        requesterUnavailable: String,
        executionInterrupted: String,
        executionTimedOut: String,
        authenticationFailed: String,
        stagingFailed: String,
        runnerLaunchFailed: String,
        processLaunchFailed: String,
        cleanupFailed: String
    ) {
        self.pamTidUnavailable = pamTidUnavailable
        self.approvalTimedOut = approvalTimedOut
        self.requesterUnavailable = requesterUnavailable
        self.executionInterrupted = executionInterrupted
        self.executionTimedOut = executionTimedOut
        self.authenticationFailed = authenticationFailed
        self.stagingFailed = stagingFailed
        self.runnerLaunchFailed = runnerLaunchFailed
        self.processLaunchFailed = processLaunchFailed
        self.cleanupFailed = cleanupFailed
    }
}
