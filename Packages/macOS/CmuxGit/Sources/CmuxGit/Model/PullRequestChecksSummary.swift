/// Mergeability information and checks for one pull request.
public struct PullRequestChecksSummary: Sendable, Equatable {
    public enum MergeStatus: String, Sendable, Equatable {
        case ready
        case blocked
        case conflict
        case unknown
    }

    public let status: PullRequestCheckStatus
    public let checks: [PullRequestCheck]
    public let mergeStatus: MergeStatus

    public init(
        status: PullRequestCheckStatus,
        checks: [PullRequestCheck],
        mergeStatus: MergeStatus
    ) {
        self.status = status
        self.checks = checks
        self.mergeStatus = mergeStatus
    }
}
