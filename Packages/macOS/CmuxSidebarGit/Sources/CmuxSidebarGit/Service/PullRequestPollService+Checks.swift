import Foundation

extension PullRequestPollService {
    /// A cleared projection must be restored from a verified remote head,
    /// never the old association cache plus a cached green check result.
    func requiresFreshPullRequestChecks(for keys: [WorkspaceGitProbeKey]) -> Bool {
        guard let host, host.pullRequestChecksEnabled else { return false }
        return keys.contains { key in
            let badge = host.panelPullRequestBadge(workspaceId: key.workspaceId, panelId: key.panelId)
            return badge?.checks == nil || badge?.checks?.status == .unavailable || badge?.isStale == true
        }
    }

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
