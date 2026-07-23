import Foundation

/// The repository discovery a pull-request refresh does before it talks to
/// GitHub: resolving a directory to its GitHub slugs and its checked-out branch.
///
/// Both are blocking filesystem work — they walk up for a `.git` directory and
/// read config files — so a refresh must keep them off the main thread. The
/// protocol exists so a host can observe or stand in for that work;
/// ``GitMetadataService`` is the production implementation and the only one the
/// app installs.
public protocol GitRepositoryDiscovering: Sendable {
    /// Ordered, de-duplicated GitHub slugs for the repository containing
    /// `directory`; empty when there is no repository or no GitHub remote.
    func repositorySlugs(forDirectory directory: String) async -> [String]

    /// The ``GitCheckedOutBranch`` for the repository containing `directory`, or
    /// ``GitCheckedOutBranch/notARepository`` when there is none.
    func checkedOutBranch(forDirectory directory: String) async -> GitCheckedOutBranch
}

extension GitMetadataService: GitRepositoryDiscovering {}
