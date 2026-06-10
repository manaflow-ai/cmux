import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Surface Directory & Branch Updates
extension TabManager {
    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let previousDirectory = gitProbeDirectory(for: tab, panelId: surfaceId)
        let normalized = normalizeDirectory(directory)
        guard tab.updatePanelDirectory(panelId: surfaceId, directory: normalized) else { return }
        let nextDirectory = normalizedWorkingDirectory(normalized)
        if previousDirectory != nextDirectory {
            guard sidebarGitMetadataWatchEnabled else {
                clearWorkspaceGitMetadata(for: WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId))
                return
            }
            scheduleWorkspacePullRequestRefresh(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
        }
    }

    func updateSurfaceGitBranch(
        tabId: UUID,
        surfaceId: UUID,
        branch: String,
        isDirty: Bool?
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let probeKey = WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: probeKey)
            return
        }
        let current = tab.panelGitBranches[surfaceId]
        let normalizedBranch = GitMetadataService.normalizedBranchName(branch) ?? branch
        let nextIsDirty = isDirty ?? (current?.branch == normalizedBranch ? current?.isDirty ?? false : false)
        guard current?.branch != normalizedBranch || current?.isDirty != nextIsDirty else { return }
        tab.updatePanelGitBranch(panelId: surfaceId, branch: normalizedBranch, isDirty: nextIsDirty)
        if let directory = gitProbeDirectory(for: tab, panelId: surfaceId) {
            workspaceGitTrackedDirectoryByKey[probeKey] = directory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: directory)
            updateWorkspaceGitMetadataFallbackTimer()
        }
        scheduleWorkspacePullRequestRefresh(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchChange"
        )
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchChange"
        )
    }

    func clearSurfaceGitBranch(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let hadBranch = tab.panelGitBranches[surfaceId] != nil
        let hadPullRequest = tab.panelPullRequests[surfaceId] != nil
        guard hadBranch || hadPullRequest else { return }
        clearWorkspacePullRequestTracking(
            for: WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
        )
        let probeKey = WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
        workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
        stopWorkspaceGitMetadataWatcher(for: probeKey)
        updateWorkspaceGitMetadataFallbackTimer()
        tab.clearPanelGitBranch(panelId: surfaceId)
        tab.clearPanelPullRequest(panelId: surfaceId)
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchCleared"
        )
    }

    func updateSurfaceShellActivity(
        tabId: UUID,
        surfaceId: UUID,
        state: Workspace.PanelShellActivityState
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.updatePanelShellActivityState(panelId: surfaceId, state: state)
        if state == .promptIdle {
            scheduleWorkspacePullRequestRefresh(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "shellPrompt"
            )
        }
    }

}
