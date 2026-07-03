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
    /// Rollup CI/check state for the PR's latest commit.
    public let ciStatus: PullRequestCIStatus

    /// Creates a probe item.
    public init(
        number: Int,
        state: String,
        url: String,
        updatedAt: String?,
        mergedAt: String? = nil,
        headRefName: String? = nil,
        baseRefName: String? = nil,
        ciStatus: PullRequestCIStatus = .neutral
    ) {
        self.number = number
        self.state = state
        self.url = url
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.ciStatus = ciStatus
    }

    private enum CodingKeys: String, CodingKey {
        case number, state, url, updatedAt, mergedAt, headRefName, baseRefName, ciStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            number: try container.decode(Int.self, forKey: .number),
            state: try container.decode(String.self, forKey: .state),
            url: try container.decode(String.self, forKey: .url),
            updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt),
            mergedAt: try container.decodeIfPresent(String.self, forKey: .mergedAt),
            headRefName: try container.decodeIfPresent(String.self, forKey: .headRefName),
            baseRefName: try container.decodeIfPresent(String.self, forKey: .baseRefName),
            ciStatus: try container.decodeIfPresent(PullRequestCIStatus.self, forKey: .ciStatus) ?? .neutral
        )
    }

    /// Returns this PR item with an updated rollup CI state.
    public func withCIStatus(_ ciStatus: PullRequestCIStatus) -> GitHubPullRequestProbeItem {
        GitHubPullRequestProbeItem(
            number: number,
            state: state,
            url: url,
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            headRefName: headRefName,
            baseRefName: baseRefName,
            ciStatus: ciStatus
        )
    }
}
