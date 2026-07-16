import Foundation

/// A stable failure category produced by the pull-request panel service.
public enum PullRequestPanelServiceError: Error, Equatable, Sendable {
    /// The workspace directory is not inside a git repository.
    case notGitRepository
    /// The repository is not on a readable local branch.
    case detachedHead
    /// The repository has no GitHub remote.
    case noGitHubRemote
    /// The GitHub CLI is missing or unauthenticated.
    case githubCLIUnavailable
    /// GitHub status could not be refreshed.
    case refreshFailed
    /// GitHub returned data that could not be decoded.
    case invalidResponse
    /// A merge or auto-merge command failed.
    case mergeFailed
    /// Opening the GitHub pull-request creation flow failed.
    case createFailed
}
