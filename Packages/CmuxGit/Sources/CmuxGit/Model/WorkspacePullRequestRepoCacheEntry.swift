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
    /// The CI rollup status per open-PR number, fetched in one GraphQL request
    /// per repo per cache window (open PRs only). Keyed by PR number — not
    /// branch — so a branch shared by multiple open PRs can't cross-render
    /// another PR's glyph. A PR without an entry renders neutral. Shared in the
    /// same cache entry as ``pullRequestsByBranch`` so every workspace on the
    /// repo reuses it.
    public let ciStatusByNumber: [Int: WorkspaceCIStatus]
    /// Branches positively known to have no pull request (so a cached entry
    /// doesn't re-trigger per-branch lookups for them).
    public let knownAbsentBranches: Set<String>

    /// Creates a cache entry.
    public init(
        fetchedAt: Date,
        pullRequestsByBranch: [String: GitHubPullRequestProbeItem],
        ciStatusByNumber: [Int: WorkspaceCIStatus] = [:],
        knownAbsentBranches: Set<String> = []
    ) {
        self.fetchedAt = fetchedAt
        self.pullRequestsByBranch = pullRequestsByBranch
        self.ciStatusByNumber = ciStatusByNumber
        self.knownAbsentBranches = knownAbsentBranches
    }
}
