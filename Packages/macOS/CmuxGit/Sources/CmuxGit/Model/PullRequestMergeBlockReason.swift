import Foundation

/// A reason the pull-request panel must disable direct merge.
public enum PullRequestMergeBlockReason: Equatable, Sendable {
    /// Draft pull requests cannot be merged.
    case draft
    /// Required reviews have not been submitted.
    case reviewRequired
    /// A reviewer requested changes.
    case changesRequested
    /// GitHub reports conflicts or another blocking merge condition.
    case githubBlocked
    /// GitHub is still computing mergeability.
    case computing
    /// Required checks are failing or require action.
    case checksFailing
    /// The pull request is already merged.
    case alreadyMerged
    /// The pull request is closed without being merged.
    case closed
}
