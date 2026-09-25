import Foundation

extension PullRequestPollService {
    /// A cleared projection must be restored from a verified remote head,
    /// never the old association cache plus a cached green check result.
    func requiresFreshPullRequestChecks(for keys: [WorkspaceGitProbeKey]) -> Bool {
        guard let host, host.pullRequestChecksEnabled else { return false }
        return keys.contains { key in
            let badge = host.panelPullRequestBadge(workspaceId: key.workspaceId, panelId: key.panelId)
            // An unavailable optional probe is a completed attempt. Keep the
            // ordinary PR metadata cache eligible so outages do not force
            // uncached REST requests on every poll. A cleared projection or
            // stale badge still requires one verified refresh.
            return badge?.checks == nil || badge?.isStale == true
        }
    }

    /// Clears the optional projection on a preference transition; a cancelled
    /// refresh cannot repopulate it after the toggle has changed.
    func clearPullRequestChecks() {
        host?.clearAllSidebarPullRequestChecks()
    }
}
