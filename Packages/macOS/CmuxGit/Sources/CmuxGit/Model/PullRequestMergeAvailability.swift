import Foundation

/// Whether direct merge is currently available for a pull request.
public enum PullRequestMergeAvailability: Equatable, Sendable {
    /// GitHub reports that direct merge is available.
    case allowed
    /// Direct merge is unavailable for the associated reason.
    case blocked(PullRequestMergeBlockReason)

    /// Creates direct-merge availability from GitHub's authoritative PR state.
    /// - Parameter pullRequest: The GitHub pull request.
    init(pullRequest: GitHubPullRequest) {
        switch pullRequest.state.uppercased() {
        case "MERGED":
            self = .blocked(.alreadyMerged)
            return
        case "CLOSED":
            self = .blocked(.closed)
            return
        case "OPEN": break
        default:
            self = .blocked(.githubBlocked)
            return
        }
        if pullRequest.isDraft {
            self = .blocked(.draft)
            return
        }

        switch pullRequest.reviewDecision?.uppercased() {
        case "CHANGES_REQUESTED":
            self = .blocked(.changesRequested)
            return
        case "REVIEW_REQUIRED":
            self = .blocked(.reviewRequired)
            return
        case nil, "", "APPROVED": break
        default:
            self = .blocked(.githubBlocked)
            return
        }

        switch pullRequest.mergeable.uppercased() {
        case "UNKNOWN":
            self = .blocked(.computing)
            return
        case "CONFLICTING":
            self = .blocked(.githubBlocked)
            return
        case "MERGEABLE": break
        default:
            self = .blocked(.githubBlocked)
            return
        }

        switch pullRequest.mergeStateStatus.uppercased() {
        case "UNKNOWN":
            self = .blocked(.computing)
        case "BLOCKED", "DIRTY", "DRAFT":
            self = .blocked(.githubBlocked)
        case "BEHIND", "CLEAN", "HAS_HOOKS", "UNSTABLE":
            self = .allowed
        default:
            self = .blocked(.githubBlocked)
        }
    }
}
