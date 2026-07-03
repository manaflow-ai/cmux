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
    /// Branches positively known to have no pull request (so a cached entry
    /// doesn't re-trigger per-branch lookups for them).
    public let knownAbsentBranches: Set<String>
    /// Whether this cache entry already includes token-gated CI rollup data.
    public let includesCIStatus: Bool
    /// CI rollups keyed by PR number, reused for targeted branch lookups inside the same cache window.
    public let ciStatusByPullRequestNumber: [Int: PullRequestCIStatus]

    /// Creates a cache entry.
    public init(
        fetchedAt: Date,
        pullRequestsByBranch: [String: GitHubPullRequestProbeItem],
        knownAbsentBranches: Set<String> = [],
        includesCIStatus: Bool = false,
        ciStatusByPullRequestNumber: [Int: PullRequestCIStatus] = [:]
    ) {
        self.fetchedAt = fetchedAt
        self.pullRequestsByBranch = pullRequestsByBranch
        self.knownAbsentBranches = knownAbsentBranches
        self.includesCIStatus = includesCIStatus
        self.ciStatusByPullRequestNumber = ciStatusByPullRequestNumber
    }
}
