import CmuxGit
import SwiftUI

extension PullRequestPanelView {
    func stateBadge(_ pullRequest: GitHubPullRequest) -> some View {
        Text(stateBadgeLabel(pullRequest))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateBadgeColor(pullRequest))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateBadgeColor(pullRequest).opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    func checkIcon(_ state: PullRequestCheckState) -> some View {
        switch state {
        case .pending:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .neutral:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    func stateBadgeLabel(_ pullRequest: GitHubPullRequest) -> String {
        if pullRequest.isDraft {
            return String(localized: "pullRequestPanel.state.draft", defaultValue: "Draft")
        }
        switch pullRequest.state.uppercased() {
        case "MERGED": return String(localized: "pullRequestPanel.state.merged", defaultValue: "Merged")
        case "CLOSED": return String(localized: "pullRequestPanel.state.closed", defaultValue: "Closed")
        default: return String(localized: "pullRequestPanel.state.open", defaultValue: "Open")
        }
    }

    func stateBadgeColor(_ pullRequest: GitHubPullRequest) -> Color {
        if pullRequest.isDraft { return .secondary }
        switch pullRequest.state.uppercased() {
        case "MERGED": return .purple
        case "CLOSED": return .red
        default: return .green
        }
    }

    func mergeMethodLabel(_ method: PullRequestMergeMethod) -> String {
        switch method {
        case .squash: return String(localized: "pullRequestPanel.merge.squash", defaultValue: "Squash")
        case .merge: return String(localized: "pullRequestPanel.merge.commit", defaultValue: "Merge Commit")
        case .rebase: return String(localized: "pullRequestPanel.merge.rebase", defaultValue: "Rebase")
        }
    }

    func mergeBlockReason(_ reason: PullRequestMergeBlockReason) -> String {
        switch reason {
        case .draft: return String(localized: "pullRequestPanel.merge.blocked.draft", defaultValue: "Draft pull requests cannot be merged.")
        case .reviewRequired: return String(localized: "pullRequestPanel.merge.blocked.reviewRequired", defaultValue: "A required review is still pending.")
        case .changesRequested: return String(localized: "pullRequestPanel.merge.blocked.changesRequested", defaultValue: "A reviewer requested changes.")
        case .githubBlocked: return String(localized: "pullRequestPanel.merge.blocked.github", defaultValue: "GitHub reports that this pull request is blocked.")
        case .computing: return String(localized: "pullRequestPanel.merge.blocked.computing", defaultValue: "GitHub is still computing merge status.")
        case .alreadyMerged: return String(localized: "pullRequestPanel.merge.blocked.merged", defaultValue: "This pull request is already merged.")
        case .closed: return String(localized: "pullRequestPanel.merge.blocked.closed", defaultValue: "This pull request is closed.")
        }
    }

    func checksSummary(_ status: PullRequestChecksStatus) -> String {
        switch status {
        case .noChecks: return String(localized: "pullRequestPanel.checks.none", defaultValue: "This pull request has no reported checks yet.")
        case .failure: return String(localized: "pullRequestPanel.checks.failing", defaultValue: "Checks failing")
        case .pending: return String(localized: "pullRequestPanel.checks.pending", defaultValue: "Checks pending")
        case .success: return String(localized: "pullRequestPanel.checks.passing", defaultValue: "Checks passing")
        case .neutral: return String(localized: "pullRequestPanel.checks.complete", defaultValue: "Checks complete")
        }
    }

    func checksSummaryColor(_ status: PullRequestChecksStatus) -> Color {
        switch status {
        case .failure: .red
        case .pending: .orange
        case .success: .green
        case .noChecks, .neutral: .secondary
        }
    }

    func reviewStatus(_ decision: String?) -> String {
        switch decision?.uppercased() {
        case "APPROVED": return String(localized: "pullRequestPanel.review.approved", defaultValue: "Approved")
        case "CHANGES_REQUESTED": return String(localized: "pullRequestPanel.review.changesRequested", defaultValue: "Changes requested")
        case "REVIEW_REQUIRED": return String(localized: "pullRequestPanel.review.required", defaultValue: "Review required")
        default: return String(localized: "pullRequestPanel.review.none", defaultValue: "No review decision")
        }
    }

    func reviewStatusIcon(_ decision: String?) -> String {
        switch decision?.uppercased() {
        case "APPROVED": "checkmark.circle.fill"
        case "CHANGES_REQUESTED": "xmark.circle.fill"
        default: "person.crop.circle.badge.questionmark"
        }
    }

    func failureIcon(_ error: PullRequestPanelServiceError) -> String {
        error == .githubCLIUnavailable ? "terminal" : "exclamationmark.triangle"
    }

    func failureMessage(_ error: PullRequestPanelServiceError) -> String {
        switch error {
        case .githubCLIUnavailable:
            return String(
                localized: "pullRequestPanel.githubCLIUnavailable",
                defaultValue: "Install the GitHub CLI to enable pull requests, issues, and checks."
            )
        case .notGitRepository:
            return String(localized: "pullRequestPanel.notGitRepository", defaultValue: "No Git repository found for this workspace.")
        case .detachedHead:
            return String(localized: "pullRequestPanel.detachedHead", defaultValue: "Check out a branch to view its pull request.")
        case .noGitHubRemote:
            return String(localized: "pullRequestPanel.noGitHubRemote", defaultValue: "No GitHub remote was found for this repository.")
        case .refreshFailed, .invalidResponse:
            return String(localized: "pullRequestPanel.refreshError.title", defaultValue: "Could not refresh pull request")
        case .mergeFailed, .createFailed:
            return String(localized: "pullRequestPanel.actionError", defaultValue: "The pull request action could not be completed.")
        }
    }
}
