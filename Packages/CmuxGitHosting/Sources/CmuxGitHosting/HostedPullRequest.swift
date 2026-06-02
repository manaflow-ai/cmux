/// A provider-agnostic snapshot of a single pull or merge request.
///
/// ``GitHostingRequestPlan/parsePullRequests(from:)`` produces these by mapping a
/// provider's REST response (GitHub, GitLab, Bitbucket, or a custom-described host)
/// through its ``GitHostingResponseSpec``. The cmux sidebar poller consumes them
/// the same way regardless of which host they came from.
public struct HostedPullRequest: Sendable, Equatable {
    /// The user-facing request number (GitHub `number`, GitLab `iid`, Bitbucket `id`).
    public let number: Int

    /// The canonical lifecycle state, after the provider's state map is applied.
    public let state: HostedPullRequestState

    /// The web URL a user opens to view the request.
    public let url: String

    /// The last-updated timestamp string as the provider reported it, if any.
    public let updatedAt: String?

    /// The merge timestamp string when the provider reports one separately, if any.
    public let mergedAt: String?

    /// The source / head branch name, used to match a request to a workspace branch.
    public let headRefName: String?

    /// The target / base branch name, when the provider reports it.
    public let baseRefName: String?

    /// Creates a normalized pull request snapshot.
    public init(
        number: Int,
        state: HostedPullRequestState,
        url: String,
        updatedAt: String? = nil,
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
