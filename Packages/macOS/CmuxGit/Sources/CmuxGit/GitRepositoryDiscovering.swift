import Foundation

/// The repository discovery a pull-request refresh does before it talks to
/// GitHub: resolving a directory to its GitHub slugs and its checked-out branch.
///
/// Both are blocking filesystem work — they walk up for a `.git` directory and
/// read config files — so a refresh must keep them off the main thread. Keeping
/// this boundary separate from GitHub transport lets the pull-request pipeline
/// resolve local candidates before it performs any authenticated network work.
/// ``GitMetadataService`` is the production implementation.
public protocol GitRepositoryDiscovering: Sendable {
    /// Ordered, de-duplicated GitHub slugs for the repository containing
    /// `directory`; empty when there is no repository or no GitHub remote.
    func repositorySlugs(forDirectory directory: String) async -> [String]

    /// The ``GitCheckedOutBranch`` for the repository containing `directory`, or
    /// ``GitCheckedOutBranch/notARepository`` when there is none.
    func checkedOutBranch(forDirectory directory: String) async -> GitCheckedOutBranch

    /// Resolves the remote slugs and checked-out branch in one bounded local
    /// metadata pass.
    func repositoryDiscoverySnapshot(
        forDirectory directory: String
    ) async -> GitRepositoryDiscoverySnapshot
}

extension GitRepositoryDiscovering {
    /// Default bridge for readers that have not implemented a combined pass.
    public func repositoryDiscoverySnapshot(
        forDirectory directory: String
    ) async -> GitRepositoryDiscoverySnapshot {
        async let repositorySlugs = repositorySlugs(forDirectory: directory)
        async let checkedOutBranch = checkedOutBranch(forDirectory: directory)
        let resolvedSlugs = await repositorySlugs
        let resolvedBranch = await checkedOutBranch
        return GitRepositoryDiscoverySnapshot(
            repositorySlugs: resolvedSlugs,
            checkedOutBranch: resolvedBranch
        )
    }
}

extension GitMetadataService: GitRepositoryDiscovering {}
