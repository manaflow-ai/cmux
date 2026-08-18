import Foundation

/// One resolved view of a repository's checked-out ref and commit.
struct GitReferenceSnapshot: Equatable, Sendable {
    let checkedOutBranch: GitCheckedOutBranch
    let headSignature: String?
    let currentCommit: String?

    var branchName: String? {
        guard case .branch(let branch) = checkedOutBranch else { return nil }
        return branch
    }
}
