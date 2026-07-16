import Foundation

/// A complete, display-ready snapshot of one branch's GitHub pull request.
public struct PullRequestPanelSnapshot: Equatable, Sendable {
    /// The canonical repository and branch identity.
    public let context: PullRequestPanelContext
    /// The pull request returned by GitHub.
    public let pullRequest: GitHubPullRequest
    /// Detailed check rows.
    public let checks: [GitHubPullRequestCheck]
    /// The checks header summary.
    public let checksStatus: PullRequestChecksStatus
    /// The unresolved review-thread count, or `nil` when unavailable.
    public let unresolvedReviewThreadCount: Int?
    /// Allowed merge methods, ordered with the default first.
    public let mergeMethods: [PullRequestMergeMethod]

    /// Direct-merge availability for the current snapshot.
    public var mergeAvailability: PullRequestMergeAvailability {
        PullRequestMergeAvailability(pullRequest: pullRequest)
    }

    /// Whether GitHub's mergeability calculation should be re-polled quickly.
    public var isMergeabilityComputing: Bool {
        mergeAvailability == .blocked(.computing)
    }

    /// Creates a pull-request panel snapshot.
    /// - Parameters:
    ///   - context: The canonical repository and branch identity.
    ///   - pullRequest: The pull request returned by GitHub.
    ///   - checks: Detailed check rows.
    ///   - checksStatus: The checks header summary.
    ///   - unresolvedReviewThreadCount: The unresolved review-thread count.
    ///   - mergeMethods: Allowed merge methods in picker order.
    public init(
        context: PullRequestPanelContext,
        pullRequest: GitHubPullRequest,
        checks: [GitHubPullRequestCheck],
        checksStatus: PullRequestChecksStatus,
        unresolvedReviewThreadCount: Int?,
        mergeMethods: [PullRequestMergeMethod]
    ) {
        self.context = context
        self.pullRequest = pullRequest
        self.checks = checks
        self.checksStatus = checksStatus
        self.unresolvedReviewThreadCount = unresolvedReviewThreadCount
        self.mergeMethods = mergeMethods
    }
}
