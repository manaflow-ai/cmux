import Foundation

/// The final result and credential lease used for one branch request.
struct WorkspacePullRequestBranchFetchOutcome: Sendable {
    let result: WorkspacePullRequestBranchFetchResult
    let authLease: GitHubAuthHeaderLease
}
