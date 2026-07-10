public import Foundation
import CmuxGit

// MARK: - O(1) local-git source ownership and same-turn refresh coalescing.

extension PullRequestPollService {
    struct SourceIdentity: Equatable {
        let directory: String
        let branch: String
    }

    /// Seeds polling for a local git snapshot when its normalized source
    /// differs from the source this panel already owns.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace containing the panel.
    ///   - panelId: Panel whose source was observed.
    ///   - directory: Local repository directory.
    ///   - branch: Current checked-out branch.
    ///   - reason: Diagnostic reason carried into the coalesced refresh pass.
    public func seedWorkspacePullRequestRefreshIfNeeded(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        branch: String,
        reason: String
    ) {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarPullRequestPollingEnabled else {
            clearWorkspacePullRequestMetadata(for: key)
            return
        }
        guard let normalizedBranch = GitMetadataService.normalizedBranchName(branch) else {
            clearWorkspacePullRequestMetadata(for: key)
            return
        }
        let source = SourceIdentity(
            directory: directory.normalizedGitProbeDirectory,
            branch: normalizedBranch
        )
        guard workspacePullRequestSourceByKey[key] != source else {
            return
        }
        workspacePullRequestSourceByKey[key] = source

        if PullRequestProbeService.shouldSkipLookup(branch: normalizedBranch) {
            if host?.panelPullRequestBadge(workspaceId: workspaceId, panelId: panelId) != nil {
                host?.clearPanelPullRequest(workspaceId: workspaceId, panelId: panelId)
            }
            clearWorkspacePullRequestTracking(for: key, preservingSource: true)
            return
        }

        let shouldBypassRepoCache = !PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
        if shouldBypassRepoCache, workspacePullRequestRefreshTask != nil {
            workspacePullRequestFollowUpShouldBypassRepoCache = true
        }
        if case .inFlight = workspacePullRequestProbeStateByKey[key] {
            markWorkspacePullRequestProbeRerunPending(
                for: key,
                bypassRepoCache: shouldBypassRepoCache
            )
        } else {
            workspacePullRequestNextPollAtByKey[key] = .distantPast
        }
#if DEBUG
        debugLog(
            "workspace.prRefresh.seed workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif
        queueWorkspacePullRequestSeedRefresh(reason: reason)
    }

    private func queueWorkspacePullRequestSeedRefresh(reason: String) {
        guard workspacePullRequestSeedRefreshTask == nil else { return }
        workspacePullRequestSeedRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.workspacePullRequestSeedRefreshTask = nil
            self.refreshTrackedWorkspacePullRequestsIfNeeded(
                reason: reason,
                allowCachedResultsOverride: nil
            )
        }
    }
}
