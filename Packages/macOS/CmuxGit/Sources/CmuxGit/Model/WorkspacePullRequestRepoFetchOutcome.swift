import Foundation

/// A repository result paired with every credential used by its requests.
struct WorkspacePullRequestRepoFetchOutcome: Sendable {
    let result: WorkspacePullRequestRepoFetchResult
    let authLeases: Set<GitHubAuthHeaderLease>
}
