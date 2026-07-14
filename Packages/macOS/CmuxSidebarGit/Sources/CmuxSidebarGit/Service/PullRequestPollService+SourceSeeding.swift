public import Foundation
import CmuxGit

// MARK: - O(1) local-git source ownership and same-turn refresh coalescing.

extension PullRequestPollService {
    struct SourceIdentity: Equatable {
        let directory: String
        let branch: String
    }

    struct PendingSeedRefresh {
        let reason: String
        var shouldBypassRepoCache: Bool
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
        runtimeMetricsRecorder.recordPullRequestSeed()
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
        if shouldBypassRepoCache {
            workspacePullRequestBypassRepoCacheKeys.insert(key)
        }
        if case .inFlight = workspacePullRequestProbeStateByKey[key] {
            markWorkspacePullRequestProbeRerunPending(
                for: key,
                reason: reason,
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
        queueWorkspacePullRequestSeedRefresh(
            reason: reason,
            shouldBypassRepoCache: shouldBypassRepoCache
        )
    }

    private func queueWorkspacePullRequestSeedRefresh(
        reason: String,
        shouldBypassRepoCache: Bool
    ) {
        if var pending = workspacePullRequestPendingSeedRefresh {
            pending.shouldBypassRepoCache = pending.shouldBypassRepoCache || shouldBypassRepoCache
            workspacePullRequestPendingSeedRefresh = pending
        } else {
            workspacePullRequestPendingSeedRefresh = PendingSeedRefresh(
                reason: reason,
                shouldBypassRepoCache: shouldBypassRepoCache
            )
        }
        // The in-flight apply owns the single global follow-up. Arming another
        // yielding task here lets both paths traverse the whole host tree.
        guard workspacePullRequestRefreshTask == nil else { return }
        guard workspacePullRequestSeedRefreshTask == nil else { return }
        workspacePullRequestSeedRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.workspacePullRequestSeedRefreshTask = nil
            // A timer/force refresh may have started while this task yielded.
            // Its apply consumes the still-pending seed and owns the follow-up.
            guard self.workspacePullRequestRefreshTask == nil,
                  let pending = self.takePendingSeedRefresh() else {
                return
            }
            self.refreshTrackedWorkspacePullRequestsIfNeeded(
                reason: pending.reason,
                allowCachedResultsOverride: pending.shouldBypassRepoCache ? false : nil
            )
        }
    }

    @discardableResult
    func takePendingSeedRefresh() -> PendingSeedRefresh? {
        workspacePullRequestSeedRefreshTask?.cancel()
        workspacePullRequestSeedRefreshTask = nil
        defer { workspacePullRequestPendingSeedRefresh = nil }
        return workspacePullRequestPendingSeedRefresh
    }
}
