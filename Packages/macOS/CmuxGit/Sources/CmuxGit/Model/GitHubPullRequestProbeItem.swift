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
    /// CI check rollup state for the PR head commit.
    public let ciStatus: PullRequestCheckStatus

    /// Creates a probe item.
    public init(
        number: Int,
        state: String,
        url: String,
        updatedAt: String?,
        mergedAt: String? = nil,
        headRefName: String? = nil,
        baseRefName: String? = nil,
        ciStatus: PullRequestCheckStatus = .neutral
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
        case number
        case state
        case url
        case updatedAt
        case mergedAt
        case headRefName
        case baseRefName
        case ciStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try container.decode(Int.self, forKey: .number)
        self.state = try container.decode(String.self, forKey: .state)
        self.url = try container.decode(String.self, forKey: .url)
        self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        self.mergedAt = try container.decodeIfPresent(String.self, forKey: .mergedAt)
        self.headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
        self.baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
        self.ciStatus = try container.decodeIfPresent(PullRequestCheckStatus.self, forKey: .ciStatus) ?? .neutral
    }
}
