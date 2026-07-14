import Foundation

/// Whether direct merge is currently available for a pull request.
public enum PullRequestMergeAvailability: Equatable, Sendable {
    /// GitHub reports that direct merge is available.
    case allowed
    /// Direct merge is unavailable for the associated reason.
    case blocked(PullRequestMergeBlockReason)

    /// Derives direct-merge availability from GitHub PR and check state.
    /// - Parameters:
    ///   - pullRequest: The GitHub pull request.
    ///   - checksStatus: The derived checks rollup.
    /// - Returns: Direct-merge availability and any blocking reason.
    static func derive(
        pullRequest: GitHubPullRequest,
        checksStatus: PullRequestChecksStatus
    ) -> PullRequestMergeAvailability {
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
        if checksStatus == .failure { return .blocked(.checksFailing) }
        let blockedMergeStates: Set<String> = [
            "BLOCKED", "BEHIND", "DIRTY", "DRAFT", "HAS_HOOKS", "UNSTABLE",
        ]
        if blockedMergeStates.contains(pullRequest.mergeStateStatus.uppercased()) {
            return .blocked(.githubBlocked)
        }
        return .allowed
    }
}
