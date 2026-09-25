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

    /// Aggregates results without treating missing pages or endpoints as passing.
    /// `complete` is false when any check source could not be fully fetched.
    public init(checks: [PullRequestCheck], mergeStatus: PullRequestMergeStatus, complete: Bool = true) {
        let status: PullRequestCheckStatus
        if checks.contains(where: { $0.status == .failure }) {
            status = .failure
        } else if checks.contains(where: { $0.status == .pending }) {
            status = .pending
        } else if !complete || checks.contains(where: { $0.status == .unavailable }) {
            status = .unavailable
        } else if checks.contains(where: { $0.status == .success }) {
            status = .success
        } else {
            status = .neutral
        }
        self.init(status: status, checks: checks, mergeStatus: mergeStatus)
    }
}
