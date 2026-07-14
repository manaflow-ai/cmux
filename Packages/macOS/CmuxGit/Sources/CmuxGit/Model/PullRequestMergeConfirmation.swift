/// The immutable pull-request identity and merge method approved by the user.
public struct PullRequestMergeConfirmation: Equatable, Sendable {
    /// The repository and branch displayed when confirmation was requested.
    public let context: PullRequestPanelContext
    /// The pull-request number displayed when confirmation was requested.
    public let number: Int
    /// The pull-request head commit displayed when confirmation was requested.
    public let headRefOid: String
    /// The merge method selected when confirmation was requested.
    public let method: PullRequestMergeMethod

    /// Creates a merge confirmation bound to one displayed pull-request snapshot.
    /// - Parameters:
    ///   - context: The displayed repository and branch.
    ///   - number: The displayed pull-request number.
    ///   - headRefOid: The displayed pull-request head commit.
    ///   - method: The selected merge method.
    public init(
        context: PullRequestPanelContext,
        number: Int,
        headRefOid: String,
        method: PullRequestMergeMethod
    ) {
        self.context = context
        self.number = number
        self.headRefOid = headRefOid
        self.method = method
    }
}
