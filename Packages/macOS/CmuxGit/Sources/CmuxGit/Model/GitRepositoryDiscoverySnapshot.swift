import Foundation

/// The local Git facts needed to associate a directory with a pull request.
public struct GitRepositoryDiscoverySnapshot: Equatable, Sendable {
    /// Ordered, de-duplicated GitHub `owner/name` remote slugs.
    public let repositorySlugs: [String]

    /// The verified checked-out branch classification.
    public let checkedOutBranch: GitCheckedOutBranch

    /// Whether remote configuration could not be read within its bounded pass.
    /// `false` also covers a repository with no configured GitHub remotes.
    public let remoteReadFailed: Bool

    /// Creates a combined repository-discovery result.
    ///
    /// - Parameters:
    ///   - repositorySlugs: Ordered GitHub remote slugs.
    ///   - checkedOutBranch: The resolved branch classification.
    ///   - remoteReadFailed: Whether remote discovery failed transiently.
    public init(
        repositorySlugs: [String],
        checkedOutBranch: GitCheckedOutBranch,
        remoteReadFailed: Bool = false
    ) {
        self.repositorySlugs = repositorySlugs
        self.checkedOutBranch = checkedOutBranch
        self.remoteReadFailed = remoteReadFailed
    }
}
