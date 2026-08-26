import Foundation

/// One resolved view of a repository's checked-out ref and commit.
nonisolated struct GitReferenceSnapshot: Equatable, Sendable {
    /// The branch, detached, or unreadable classification returned by Git or the file parser.
    let checkedOutBranch: GitCheckedOutBranch

    /// A stable signature that changes when the symbolic ref or resolved commit changes.
    let headSignature: String?

    /// The resolved object ID, when HEAD points to a commit.
    let currentCommit: String?

    /// The normalized branch name when this snapshot represents a branch checkout.
    var branchName: String? {
        guard case .branch(let branch) = checkedOutBranch else { return nil }
        return branch
    }

    /// Additional bounded storage paths Git reports for watcher invalidation.
    let storageWatchPaths: [String] = []

    /// Whether this snapshot used storage-independent Git plumbing.
    let usesGitPlumbing: Bool = false
}
