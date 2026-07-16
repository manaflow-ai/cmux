import Foundation

/// The canonical repository and branch identity used for pull-request caching and `gh` commands.
public struct PullRequestPanelContext: Equatable, Hashable, Sendable {
    /// The absolute root of the checked-out repository.
    public let repositoryRoot: String

    /// The currently checked-out branch.
    public let branch: String

    /// The preferred GitHub `owner/name` slug from the repository remotes.
    public let repositorySlug: String

    /// Creates a canonical pull-request context.
    /// - Parameters:
    ///   - repositoryRoot: The absolute root of the checked-out repository.
    ///   - branch: The currently checked-out branch.
    ///   - repositorySlug: The preferred GitHub `owner/name` slug.
    public init(repositoryRoot: String, branch: String, repositorySlug: String) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.repositorySlug = repositorySlug
    }
}
