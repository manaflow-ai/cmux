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
        default: break
        }
        if pullRequest.isDraft { return .blocked(.draft) }

        switch pullRequest.reviewDecision?.uppercased() {
        case "CHANGES_REQUESTED": return .blocked(.changesRequested)
        case "REVIEW_REQUIRED": return .blocked(.reviewRequired)
        default: break
        }

        if pullRequest.mergeable.uppercased() == "UNKNOWN"
            || pullRequest.mergeStateStatus.uppercased() == "UNKNOWN" {
            return .blocked(.computing)
        }
        if pullRequest.mergeable.uppercased() == "CONFLICTING" {
            return .blocked(.githubBlocked)
        }
        let blockedMergeStates: Set<String> = [
            "BLOCKED", "BEHIND", "DIRTY", "DRAFT",
        ]
        if blockedMergeStates.contains(pullRequest.mergeStateStatus.uppercased()) {
            return .blocked(.githubBlocked)
        }
        return .allowed
    }
}
