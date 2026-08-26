import Foundation

/// The local Git facts needed to associate a directory with a pull request.
public struct GitRepositoryDiscoverySnapshot: Equatable, Sendable {
    /// Ordered, de-duplicated GitHub `owner/name` remote slugs.
    public let repositorySlugs: [String]

    /// The verified checked-out branch classification.
    public let checkedOutBranch: GitCheckedOutBranch

    /// Creates a combined repository-discovery result.
    ///
    /// - Parameters:
    ///   - repositorySlugs: Ordered GitHub remote slugs.
    ///   - checkedOutBranch: The resolved branch classification.
    public init(
        repositorySlugs: [String],
        checkedOutBranch: GitCheckedOutBranch
    ) {
        self.repositorySlugs = repositorySlugs
        self.checkedOutBranch = checkedOutBranch
    }
}
