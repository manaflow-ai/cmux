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
    /// The ``PullRequestCheckStatus`` raw value (`"neutral"`/`"success"`/`"failure"`).
    public let ciStatusRawValue: String
    /// The branch the PR was matched for.
    public let branch: String

    /// Creates a resolved item.
    public init(
        number: Int,
        urlString: String,
        statusRawValue: String,
        ciStatusRawValue: String = PullRequestCheckStatus.neutral.rawValue,
        branch: String
    ) {
        self.number = number
        self.urlString = urlString
        self.statusRawValue = statusRawValue
        self.ciStatusRawValue = ciStatusRawValue
        self.branch = branch
    }
}
