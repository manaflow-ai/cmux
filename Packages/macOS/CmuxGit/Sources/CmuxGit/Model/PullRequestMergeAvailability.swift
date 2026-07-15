import Foundation

/// Whether direct merge is currently available for a pull request.
public enum PullRequestMergeAvailability: Equatable, Sendable {
    /// GitHub reports that direct merge is available.
    case allowed
    /// Direct merge is unavailable for the associated reason.
    case blocked(PullRequestMergeBlockReason)

    /// Derives direct-merge availability from GitHub's authoritative PR state.
    /// - Parameter pullRequest: The GitHub pull request.
    /// - Returns: Direct-merge availability and any blocking reason.
    static func derive(pullRequest: GitHubPullRequest) -> PullRequestMergeAvailability {
        switch pullRequest.state.uppercased() {
        case "MERGED": return .blocked(.alreadyMerged)
        case "CLOSED": return .blocked(.closed)
        case "OPEN": break
        default: return .blocked(.githubBlocked)
        }
        if pullRequest.isDraft { return .blocked(.draft) }

        switch pullRequest.reviewDecision?.uppercased() {
        case "CHANGES_REQUESTED": return .blocked(.changesRequested)
        case "REVIEW_REQUIRED": return .blocked(.reviewRequired)
        case nil, "", "APPROVED": break
        default: return .blocked(.githubBlocked)
        }

        switch pullRequest.mergeable.uppercased() {
        case "UNKNOWN": return .blocked(.computing)
        case "CONFLICTING": return .blocked(.githubBlocked)
        case "MERGEABLE": break
        default: return .blocked(.githubBlocked)
        }

        switch pullRequest.mergeStateStatus.uppercased() {
        case "UNKNOWN": return .blocked(.computing)
        case "BLOCKED", "DIRTY", "DRAFT": return .blocked(.githubBlocked)
        case "BEHIND", "CLEAN", "HAS_HOOKS", "UNSTABLE": return .allowed
        default: return .blocked(.githubBlocked)
        }
    }
}
