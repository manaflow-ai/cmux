import Foundation

/// The pull request a refresh resolved for one panel, reduced to the fields a
/// badge needs.
public struct WorkspacePullRequestResolvedItem: Sendable {
    /// The pull request number.
    public let number: Int
    /// The PR's html URL string.
    public let urlString: String
    /// The ``PullRequestStatus`` raw value (`"open"`/`"merged"`/`"closed"`),
    /// kept as a string so app-side status enums can bridge via `rawValue`.
    public let statusRawValue: String
    /// The branch the PR was matched for.
    public let branch: String
    /// The repository slug used for the GitHub API request.
    public let repoSlug: String
    /// The PR head commit SHA, used to query check runs.
    public let headSHA: String?
    /// Checks and mergeability when the optional checks probe was enabled.
    public let checks: PullRequestChecksSummary?

    /// Creates a resolved item.
    public init(
        number: Int,
        urlString: String,
        statusRawValue: String,
        branch: String,
        repoSlug: String = "",
        headSHA: String? = nil,
        checks: PullRequestChecksSummary? = nil
    ) {
        self.number = number
        self.urlString = urlString
        self.statusRawValue = statusRawValue
        self.branch = branch
        self.repoSlug = repoSlug
        self.headSHA = headSHA
        self.checks = checks
    }

    /// Returns this item with the optional checks summary attached.
    public func withChecks(_ checks: PullRequestChecksSummary?) -> Self {
        Self(
            number: number,
            urlString: urlString,
            statusRawValue: statusRawValue,
            branch: branch,
            repoSlug: repoSlug,
            headSHA: headSHA,
            checks: checks
        )
    }
}
