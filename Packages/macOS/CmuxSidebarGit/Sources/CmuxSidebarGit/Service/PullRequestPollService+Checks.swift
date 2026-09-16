import Foundation

extension PullRequestPollService {
    /// Clears the optional projection on a preference transition; a cancelled
    /// refresh cannot repopulate it after the toggle has changed.
    func clearPullRequestChecks() {
        guard let host else { return }
        for workspaceID in host.orderedWorkspaceIds() {
            for panelID in host.panelPullRequestPanelIds(in: workspaceID) {
                guard let badge = host.panelPullRequestBadge(workspaceId: workspaceID, panelId: panelID),
                      badge.checks != nil else { continue }
                host.updatePanelPullRequest(
                    workspaceId: workspaceID, panelId: panelID,
                    badge: SidebarPullRequestBadge(
                        number: badge.number, label: badge.label, url: badge.url,
                        status: badge.status, branch: badge.branch, isStale: badge.isStale
                    )
                )
            }
        }
    }
}
