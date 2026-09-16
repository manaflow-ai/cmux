import Foundation
import CmuxSidebar

extension Workspace {
    /// Stores a CLI-owned pull-request association at workspace scope. The
    /// watcher keeps its panel state separately and therefore cannot clear or
    /// replace this value during branch refreshes.
    func attachManualPullRequest(
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) {
        let state = SidebarPullRequestState(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: branch
        )
        if manualPullRequest != state { manualPullRequest = state }
    }

    /// Matching fresh watcher results advance the manual link's status too,
    /// including closed/reopened transitions, so changing branch cannot
    /// resurrect the status originally supplied by the handoff.
    func reconcileManualPullRequest(with state: SidebarPullRequestState) {
        guard let manual = manualPullRequest, !state.isStale,
              manual.number == state.number,
              manual.url.absoluteString.lowercased() == state.url.absoluteString.lowercased() else { return }
        let updated = SidebarPullRequestState(
            number: manual.number, label: manual.label, url: manual.url,
            status: state.status, branch: manual.branch
        )
        if updated != manual { manualPullRequest = updated }
    }

    /// Removes the CLI-owned workspace pull-request association.
    func clearManualPullRequest() {
        manualPullRequest = nil
    }

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = panelPullRequests.filter { panelId, state in
            guard !cloudDirectoryProvenanceRequired(panelId: panelId) else { return false }
            if usesRemoteDirectoryProvenance, effectivePanelDirectory(panelId: panelId) == nil {
                return false
            }
            guard let pullRequestBranch = state.branch?.normalizedSidebarBranchName else {
                return true
            }
            return reportedPanelGitBranch(panelId: panelId)?.branch.normalizedSidebarBranchName == pullRequestBranch
        }
        return SidebarBranchOrdering().orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil,
            additionalPullRequests: manualPullRequest.map { [$0] } ?? []
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

}
