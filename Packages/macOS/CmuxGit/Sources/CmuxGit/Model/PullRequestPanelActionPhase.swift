import Foundation

/// The state of a user-initiated pull-request mutation.
public enum PullRequestPanelActionPhase: Equatable, Sendable {
    /// No mutation is running and the last mutation did not fail.
    case idle
    /// A direct merge is running.
    case merging
    /// Auto-merge is being enabled.
    case enablingAutoMerge
    /// Auto-merge is being disabled.
    case disablingAutoMerge
    /// GitHub's web pull-request creation flow is being opened.
    case creatingPullRequest
    /// The last mutation failed.
    case failed(PullRequestPanelServiceError)

    /// Whether a mutation is currently in progress.
    public var isBusy: Bool {
        switch self {
        case .merging, .enablingAutoMerge, .disablingAutoMerge, .creatingPullRequest:
            true
        case .idle, .failed:
            false
        }
    }
}
