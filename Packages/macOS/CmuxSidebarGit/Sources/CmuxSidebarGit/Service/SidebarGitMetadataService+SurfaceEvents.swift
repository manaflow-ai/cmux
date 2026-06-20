public import Foundation
internal import CmuxGit

// MARK: - Externally reported surface events (directory and branch changes).

extension SidebarGitMetadataService {
    public func updateSurfaceDirectory(workspaceId: UUID, panelId: UUID, directory: String) {
        guard let host, host.workspaceExists(workspaceId) else { return }
        let previousDirectory = host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId)
        let normalized = directory.normalizedGitProbeDirectory
        guard host.updatePanelDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: normalized
        ) else { return }
        let nextDirectory = normalized.nonEmptyNormalizedGitProbeDirectory
        if previousDirectory != nextDirectory {
            guard sidebarGitMetadataWatchEnabled else {
                clearWorkspaceGitMetadata(for: WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId))
                return
            }
            pullRequestProbing.scheduleWorkspacePullRequestRefresh(
                workspaceId: workspaceId,
                panelId: panelId,
                reason: "directoryChange"
            )
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: workspaceId,
                panelId: panelId,
                reason: "directoryChange"
            )
        }
    }

    public func updateSurfaceGitBranch(
        workspaceId: UUID,
        panelId: UUID,
        branch: String,
        isDirty: Bool?
    ) {
        guard let host, host.workspaceExists(workspaceId) else { return }
        let probeKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: probeKey)
            return
        }
        let current = host.panelGitBranch(workspaceId: workspaceId, panelId: panelId)
        let normalizedBranch = GitMetadataService.normalizedBranchName(branch) ?? branch
        let nextIsDirty = isDirty ?? (current?.branch == normalizedBranch ? current?.isDirty ?? false : false)
        guard current?.branch != normalizedBranch || current?.isDirty != nextIsDirty else { return }
        host.updatePanelGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: normalizedBranch,
            isDirty: nextIsDirty
        )
        if let directory = host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId) {
            workspaceGitTrackedDirectoryByKey[probeKey] = directory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: directory)
            updateWorkspaceGitMetadataFallbackTimer()
        }
        pullRequestProbing.scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "branchChange"
        )
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "branchChange"
        )
    }

    public func clearSurfaceGitBranch(workspaceId: UUID, panelId: UUID) {
        guard let host, host.workspaceExists(workspaceId) else { return }
        let hadBranch = host.panelGitBranch(workspaceId: workspaceId, panelId: panelId) != nil
        let hadPullRequest = host.panelPullRequestBadge(workspaceId: workspaceId, panelId: panelId) != nil
        guard hadBranch || hadPullRequest else { return }
        pullRequestProbing.clearWorkspacePullRequestTracking(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let probeKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
        stopWorkspaceGitMetadataWatcher(for: probeKey)
        updateWorkspaceGitMetadataFallbackTimer()
        host.clearPanelGitBranch(workspaceId: workspaceId, panelId: panelId)
        host.clearPanelPullRequest(workspaceId: workspaceId, panelId: panelId)
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "branchCleared"
        )
    }
}
