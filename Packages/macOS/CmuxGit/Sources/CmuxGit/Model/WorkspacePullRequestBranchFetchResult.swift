import Foundation

/// The outcome of one per-branch pull-request lookup.
enum WorkspacePullRequestBranchFetchResult: Sendable {
    case found(GitHubPullRequestProbeItem)
    case notFound
    case transientFailure
}
