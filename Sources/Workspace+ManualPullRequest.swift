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
        let changed = sidebarMetadata.attachManualPullRequest(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: branch
        )
        if changed { objectWillChange.send() }
    }

    /// Matching fresh watcher results advance the manual link's status too,
    /// including closed/reopened transitions, so changing branch cannot
    /// resurrect the status originally supplied by the handoff.
    func reconcileManualPullRequest(with state: SidebarPullRequestState) {
        if sidebarMetadata.reconcileManualPullRequest(with: state) {
            objectWillChange.send()
        }
    }

    /// Removes the CLI-owned workspace pull-request association.
    func clearManualPullRequest() {
        if sidebarMetadata.clearManualPullRequest() {
            objectWillChange.send()
        }
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
