public import Foundation

/// The pull-request fields returned by the panel's exact `gh pr view <branch> --json ...` query.
public struct GitHubPullRequest: Decodable, Equatable, Sendable {
    /// The GitHub pull-request number.
    public let number: Int
    /// The pull-request title.
    public let title: String
    /// The GitHub state (`OPEN`, `MERGED`, or `CLOSED`).
    public let state: String
    /// The canonical GitHub pull-request URL.
    public let url: URL
    /// The checks included in GitHub's status rollup.
    let statusCheckRollup: [GitHubPullRequestRollupCheck]
    /// The last GitHub update time.
    public let updatedAt: Date
    /// Whether the pull request is a draft.
    public let isDraft: Bool
    /// GitHub's mergeability value (`MERGEABLE`, `CONFLICTING`, or `UNKNOWN`).
    public let mergeable: String
    /// GitHub's review decision, when one is available.
    public let reviewDecision: String?
    /// GitHub's detailed merge-state value.
    public let mergeStateStatus: String
    /// Whether GitHub currently has auto-merge configured.
    public let isAutoMergeEnabled: Bool
    /// The base branch name.
    public let baseRefName: String
    /// The head branch name.
    public let headRefName: String
    /// The base commit object ID.
    public let baseRefOid: String
    /// The head commit object ID.
    public let headRefOid: String

    private enum CodingKeys: String, CodingKey {
        case number, title, state, url, statusCheckRollup, updatedAt, isDraft
        case mergeable, reviewDecision, mergeStateStatus, autoMergeRequest
        case baseRefName, headRefName, baseRefOid, headRefOid
    }

    /// Decodes the GitHub CLI payload, reducing the nullable `autoMergeRequest` object to a stable boolean.
    /// - Parameter decoder: The GitHub CLI JSON decoder.
    /// - Throws: A decoding error when required pull-request fields are absent or malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        state = try container.decode(String.self, forKey: .state)
        url = try container.decode(URL.self, forKey: .url)
        statusCheckRollup = try container.decodeIfPresent(
            [GitHubPullRequestRollupCheck].self,
            forKey: .statusCheckRollup
        ) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        mergeable = try container.decode(String.self, forKey: .mergeable)
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        mergeStateStatus = try container.decode(String.self, forKey: .mergeStateStatus)
        isAutoMergeEnabled = container.contains(.autoMergeRequest)
            && !(try container.decodeNil(forKey: .autoMergeRequest))
        baseRefName = try container.decode(String.self, forKey: .baseRefName)
        headRefName = try container.decode(String.self, forKey: .headRefName)
        baseRefOid = try container.decode(String.self, forKey: .baseRefOid)
        headRefOid = try container.decode(String.self, forKey: .headRefOid)
    }
}
