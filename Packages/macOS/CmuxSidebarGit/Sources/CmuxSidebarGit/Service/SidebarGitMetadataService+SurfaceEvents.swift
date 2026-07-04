public import Foundation
internal import CmuxGit

// MARK: - Externally reported surface events (directory and branch changes).

extension SidebarGitMetadataService {
    /// Records a panel's directory change and reschedules probes when the
    /// effective probe directory changed (see ``SidebarGitMetadataServing``).
    /// `displayLabel` optionally carries a human-friendly sidebar label
    /// reported alongside the real path; it is stored by the host only when
    /// the directory write is accepted.
    public func updateSurfaceDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) {
        updateSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            displayLabel: displayLabel,
            clearMetadataBeforeRefresh: false
        ) { host, workspaceId, panelId, normalized, displayLabel in
            host.updatePanelDirectory(
                workspaceId: workspaceId,
                panelId: panelId,
                directory: normalized,
                displayLabel: displayLabel
            )
        }
    }

    /// Records a trusted remote directory report and clears stale git/PR
    /// metadata before scheduling fresh probes for the remote path.
    public func updateRemoteSurfaceDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) {
        updateSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            displayLabel: displayLabel,
            clearMetadataBeforeRefresh: true
        ) { host, workspaceId, panelId, normalized, displayLabel in
            host.updateRemotePanelDirectory(
                workspaceId: workspaceId,
                panelId: panelId,
                directory: normalized,
                displayLabel: displayLabel
            )
        }
    }

    private func updateSurfaceDirectory(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        displayLabel: String?,
        clearMetadataBeforeRefresh: Bool,
        recordDirectory: (any SidebarGitHosting, UUID, UUID, String, String?) -> Bool
    ) {
        guard let host, host.workspaceExists(workspaceId) else { return }
        let previousDirectory = host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId)
        let hadTrustedRemoteDirectory = clearMetadataBeforeRefresh &&
            host.hasTrustedRemotePanelDirectory(workspaceId: workspaceId, panelId: panelId)
        let normalized = directory.normalizedGitProbeDirectory
        guard recordDirectory(host, workspaceId, panelId, normalized, displayLabel) else { return }
        let nextDirectory = normalized.nonEmptyNormalizedGitProbeDirectory
        if previousDirectory != nextDirectory || (clearMetadataBeforeRefresh && !hadTrustedRemoteDirectory) {
            let probeKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
            if clearMetadataBeforeRefresh {
                if host.isRemoteWorkspace(workspaceId) == true {
                    clearWorkspaceGitProbeTracking(for: probeKey)
                    if hadTrustedRemoteDirectory, previousDirectory != nextDirectory {
                        host.clearPanelGitBranch(workspaceId: workspaceId, panelId: panelId)
                        host.clearPanelPullRequest(workspaceId: workspaceId, panelId: panelId)
                    }
                    return
                }
                clearWorkspaceGitMetadata(for: probeKey)
            }
            guard sidebarGitMetadataWatchEnabled else {
                if !clearMetadataBeforeRefresh {
                    clearWorkspaceGitMetadata(for: probeKey)
                }
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
        let branchChanged = current?.branch != normalizedBranch || current?.isDirty != nextIsDirty
        if branchChanged {
            host.updatePanelGitBranch(
                workspaceId: workspaceId,
                panelId: panelId,
                branch: normalizedBranch,
                isDirty: nextIsDirty
            )
        }
        if host.isRemoteWorkspace(workspaceId) == true {
            clearWorkspaceGitProbe(probeKey)
            workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
            updateWorkspaceGitMetadataFallbackTimer()
            pullRequestProbing.clearWorkspacePullRequestTracking(workspaceId: workspaceId, panelId: panelId)
            return
        }
        guard branchChanged else { return }
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
