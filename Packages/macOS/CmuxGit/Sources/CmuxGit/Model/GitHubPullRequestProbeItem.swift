import Foundation

/// One pull request as the GitHub probe caches it: the fields needed to pick
/// the best PR for a branch and render a badge.
///
/// `state` is the raw GitHub state string (the probe synthesizes `"MERGED"`
/// when `mergedAt` is set); parse it with ``PullRequestStatus/init(githubState:)``.
public struct GitHubPullRequestProbeItem: Decodable, Equatable, Sendable {
    /// The pull request number.
    public let number: Int
    /// Raw GitHub state string (`"OPEN"`/`"MERGED"`/`"CLOSED"`, any case).
    public let state: String
    /// The PR's html URL string.
    public let url: String
    /// ISO-8601 `updatedAt` timestamp, if known.
    public let updatedAt: String?
    /// ISO-8601 `mergedAt` timestamp, if the PR merged.
    public let mergedAt: String?
    /// The PR's head (source) branch name, if known.
    public let headRefName: String?
    /// The PR's base (target) branch name, if known.
    public let baseRefName: String?

    /// Creates a probe item.
    public init(
        number: Int,
        state: String,
        url: String,
        updatedAt: String?,
        mergedAt: String? = nil,
        headRefName: String? = nil,
        baseRefName: String? = nil
    ) {
        self.number = number
        self.state = state
        self.url = url
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.headRefName = headRefName
        self.baseRefName = baseRefName
    }
}
