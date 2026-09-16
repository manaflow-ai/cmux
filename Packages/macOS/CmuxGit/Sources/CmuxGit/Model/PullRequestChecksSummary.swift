/// Mergeability information and checks for one pull request.
public struct PullRequestChecksSummary: Sendable, Equatable {

    /// Aggregate check outcome; unavailable data never implies success.
    public let status: PullRequestCheckStatus
    /// Individual check results included in this summary.
    public let checks: [PullRequestCheck]
    /// Merge conflicts or other blockers, independent of check results.
    public let mergeStatus: PullRequestMergeStatus

    /// Creates a summary with separate CI and mergeability outcomes.
    public init(
        status: PullRequestCheckStatus,
        checks: [PullRequestCheck],
        mergeStatus: PullRequestMergeStatus
    ) {
        self.status = status
        self.checks = checks
        self.mergeStatus = mergeStatus
    }
}
