import Foundation

/// Cacheable successful content for a repository branch.
public enum PullRequestPanelContent: Equatable, Sendable {
    /// A pull request and all of its panel details.
    case pullRequest(PullRequestPanelSnapshot)
    /// The branch currently has no pull request.
    case noPullRequest(PullRequestPanelContext)

    /// The canonical repository and branch identity.
    public var context: PullRequestPanelContext {
        switch self {
        case .pullRequest(let snapshot): snapshot.context
        case .noPullRequest(let context): context
        }
    }
}
