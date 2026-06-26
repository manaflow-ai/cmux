public import Foundation

/// One repository's cached pull-request lookup state, keyed by branch.
///
/// The caller owns the cache (slug → entry) and hands it back on each refresh;
/// the service decides freshness with ``PullRequestProbeService/repoCacheLifetime``.
public struct WorkspacePullRequestRepoCacheEntry: Sendable {
    /// When this entry was fetched.
    public let fetchedAt: Date
    /// The best pull request per normalized branch name.
    public let pullRequestsByBranch: [String: GitHubPullRequestProbeItem]
    /// CI rollups keyed by pull-request number for the current cache window.
    public let ciStatusesByPullRequestNumber: [Int: PullRequestCheckStatus]
    /// CI rollups keyed by normalized head branch for the current cache window.
    public let ciStatusesByBranch: [String: PullRequestCheckStatus]
    /// Branches positively known to have no pull request (so a cached entry
    /// doesn't re-trigger per-branch lookups for them).
    public let knownAbsentBranches: Set<String>

    /// Creates a cache entry.
    public init(
        fetchedAt: Date,
        pullRequestsByBranch: [String: GitHubPullRequestProbeItem],
        ciStatusesByPullRequestNumber: [Int: PullRequestCheckStatus] = [:],
        ciStatusesByBranch: [String: PullRequestCheckStatus] = [:],
        knownAbsentBranches: Set<String> = []
    ) {
        self.fetchedAt = fetchedAt
        self.pullRequestsByBranch = pullRequestsByBranch
        self.ciStatusesByPullRequestNumber = ciStatusesByPullRequestNumber
        self.ciStatusesByBranch = ciStatusesByBranch
        self.knownAbsentBranches = knownAbsentBranches
    }
}
