import Foundation

/// One resolved view of a repository's checked-out ref and commit.
struct GitReferenceSnapshot: Equatable, Sendable {
    /// The branch/detached/unreadable classification returned by Git or the file parser.
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
}
