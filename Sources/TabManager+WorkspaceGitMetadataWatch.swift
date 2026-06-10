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


// MARK: - Workspace Git Metadata Watching
extension TabManager {
    func updateWorkspaceGitMetadataFallbackTimer() {
        guard sidebarGitMetadataWatchEnabled,
              !workspaceGitTrackedDirectoryByKey.isEmpty else {
            workspaceGitMetadataFallbackTask?.cancel()
            workspaceGitMetadataFallbackTask = nil
            return
        }

        guard workspaceGitMetadataFallbackTask == nil else {
            return
        }

        let clock = gitPollClock
        let interval = Self.workspaceGitMetadataFallbackRefreshInterval
        workspaceGitMetadataFallbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Bounded, cancellable fallback interval on the injected clock
                // (replaces the repeating DispatchSource timer).
                do {
                    try await clock.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
            }
        }
    }

    private func refreshTrackedWorkspaceGitMetadata(reason: String) {
        let activeProbeKeys = activeWorkspaceGitProbeKeys

        for workspace in tabs {
            for panelId in trackedWorkspaceGitMetadataPollCandidatePanelIds(
                in: workspace,
                activeProbeKeys: activeProbeKeys
            ) {
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
    }

    var sidebarGitMetadataWatchEnabled: Bool {
        SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard)
    }

    var sidebarPullRequestPollingEnabled: Bool {
        SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard)
    }

    func sidebarMetadataSettingsDidChange() {
        sidebarGitMetadataWatchSettingsDidChange()
        sidebarPullRequestPollingSettingsDidChange()
    }

    private func sidebarGitMetadataWatchSettingsDidChange() {
        let isEnabled = sidebarGitMetadataWatchEnabled
        guard isEnabled != lastSidebarGitMetadataWatchEnabled else {
            return
        }
        lastSidebarGitMetadataWatchEnabled = isEnabled

        guard isEnabled else {
            stopAllWorkspaceGitMetadataWatchers()
            workspaceGitMetadataFallbackTask?.cancel()
            workspaceGitMetadataFallbackTask = nil
            workspaceGitProbeStateByKey.removeAll()
            for task in workspaceGitProbeTasksByKey.values {
                task.cancel()
            }
            workspaceGitProbeTasksByKey.removeAll()
            cancelAllWorkspaceGitSnapshotTasks()
            workspaceGitTrackedDirectoryByKey.removeAll()
            workspaceGitCleanIndexSignatureByKey.removeAll()
            workspaceGitCleanIndexContentSignatureByKey.removeAll()
            workspaceGitHeadSignatureByKey.removeAll()
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarGitMetadata()
            return
        }

        restartWorkspaceGitMetadataWatching(reason: "gitWatchSettingEnabled")
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func sidebarPullRequestPollingSettingsDidChange() {
        let isEnabled = sidebarPullRequestPollingEnabled
        guard isEnabled != lastSidebarPullRequestPollingEnabled else {
            return
        }
        lastSidebarPullRequestPollingEnabled = isEnabled

        guard isEnabled else {
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarPullRequestMetadata()
            return
        }

        refreshTrackedWorkspacePullRequestsIfNeeded(reason: "pullRequestVisibilityEnabled")
    }

    private func restartWorkspaceGitMetadataWatching(reason: String) {
        for workspace in tabs where !workspace.isRemoteWorkspace {
            for panelId in workspace.panels.keys {
                guard workspace.terminalPanel(for: panelId) != nil else {
                    continue
                }
                if let directory = gitProbeDirectory(for: workspace, panelId: panelId) {
                    let key = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                    workspaceGitTrackedDirectoryByKey[key] = directory
                    updateWorkspaceGitMetadataWatcher(for: key, directory: directory)
                }
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
        updateWorkspaceGitMetadataFallbackTimer()
    }

    func updateWorkspaceGitMetadataWatcher(
        for key: WorkspaceGitProbeKey,
        directory: String
    ) {
        guard sidebarGitMetadataWatchEnabled else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatcherSourceDirectoryByKey[key] == directory,
           workspaceGitMetadataWatchersByKey[key] != nil {
            if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory != directory {
                workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            }
            return
        }

        if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory == directory {
            return
        }

        workspaceGitMetadataWatcherDescriptorGeneration &+= 1
        let request = WorkspaceGitMetadataWatcherDescriptorRequest(
            generation: workspaceGitMetadataWatcherDescriptorGeneration,
            directory: directory
        )
        workspaceGitMetadataWatcherDescriptorRequestsByKey[key] = request

        Task { [weak self] in
            guard let gitMetadataService = self?.gitMetadataService else { return }
            let watchedPaths = await gitMetadataService.watchedPaths(for: directory)
            await MainActor.run { [weak self] in
                self?.applyWorkspaceGitMetadataWatcherDescriptor(
                    watchedPaths,
                    for: key,
                    request: request
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataWatcherDescriptor(
        _ watchedPaths: [String]?,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) {
        guard workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request else {
            return
        }
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)

        guard sidebarGitMetadataWatchEnabled,
              workspaceGitTrackedDirectoryByKey[key] == request.directory,
              let watchedPaths else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatchersByKey[key]?.watchedPaths == watchedPaths {
            workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
            return
        }

        stopWorkspaceGitMetadataWatcher(for: key)
        if let watcher = RecursivePathWatcher(paths: watchedPaths) {
            workspaceGitMetadataWatchersByKey[key] = watcher
            let events = watcher.events
            workspaceGitMetadataWatcherRefreshTasksByKey[key] = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId,
                        panelId: key.panelId,
                        reason: "filesystemEvent"
                    )
                }
            }
        }
        workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
    }

    func stopWorkspaceGitMetadataWatcher(for key: WorkspaceGitProbeKey) {
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherRefreshTasksByKey.removeValue(forKey: key)?.cancel()
        // Dropping the last reference runs the watcher's deinit synchronously,
        // which invalidates the FSEventStream on its shared queue before this
        // returns. The consumer task captures the events stream (not the watcher),
        // so removal here is the last reference.
        workspaceGitMetadataWatchersByKey.removeValue(forKey: key)
    }

    func stopWorkspaceGitMetadataWatchers(workspaceId: UUID) {
        let keys = workspaceGitMetadataWatchersByKey.keys.filter { $0.workspaceId == workspaceId }
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    private func stopAllWorkspaceGitMetadataWatchers() {
        for task in workspaceGitMetadataWatcherRefreshTasksByKey.values {
            task.cancel()
        }
        workspaceGitMetadataWatcherRefreshTasksByKey.removeAll()
        // Dropping the references runs each watcher's deinit synchronously,
        // invalidating its FSEventStream.
        workspaceGitMetadataWatchersByKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
    }

    private var activeWorkspaceGitProbeKeys: Set<WorkspaceGitProbeKey> {
        Set(workspaceGitProbeStateByKey.compactMap { key, state in
            guard case .inFlight = state else { return nil }
            return key
        })
    }

    func markWorkspaceGitProbeRerunPending(for key: WorkspaceGitProbeKey) {
        guard case .inFlight(let rerunPending) = workspaceGitProbeStateByKey[key],
              !rerunPending else {
            return
        }
        workspaceGitProbeStateByKey[key] = .inFlight(rerunPending: true)
    }

    func workspaceGitProbeRerunPending(for key: WorkspaceGitProbeKey) -> Bool {
        guard case .inFlight(let rerunPending) = workspaceGitProbeStateByKey[key] else {
            return false
        }
        return rerunPending
    }

    func isSelectedFocusedPanel(workspace: Workspace, panelId: UUID) -> Bool {
        selectedWorkspace?.id == workspace.id && selectedWorkspace?.focusedPanelId == panelId
    }

    nonisolated static func jitteredPollInterval(base: TimeInterval) -> TimeInterval {
        let jitter = base * Self.workspacePullRequestPollJitterFraction
        return base + Double.random(in: -jitter...jitter)
    }

    func refreshTrackedWorkspaceGitMetadataForTesting() {
        refreshTrackedWorkspaceGitMetadata(reason: "test")
    }

    func sidebarGitMetadataWatchSettingsDidChangeForTesting() {
        sidebarMetadataSettingsDidChange()
    }

    func trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        let activeProbeKeys = activeWorkspaceGitProbeKeys
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else {
            return []
        }
        return trackedWorkspaceGitMetadataPollCandidatePanelIds(
            in: workspace,
            activeProbeKeys: activeProbeKeys
        )
    }

    func activeWorkspaceGitProbePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        let probeKeys = Set(workspaceGitProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTasksByKey.keys.filter { $0.workspaceId == workspaceId })
        return Set(probeKeys.map(\.panelId))
    }

    func workspacePullRequestTrackedPanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        let probeKeys = Set(workspacePullRequestProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspacePullRequestNextPollAtByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspacePullRequestLastTerminalStateRefreshAtByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspacePullRequestTransientFailureCountByKey.keys.filter { $0.workspaceId == workspaceId })
        return Set(probeKeys.map(\.panelId))
    }

    private func trackedWorkspaceGitMetadataPollCandidatePanelIds(
        in workspace: Workspace,
        activeProbeKeys: Set<WorkspaceGitProbeKey>
    ) -> Set<UUID> {
        var candidatePanelIds = Set(workspace.panelGitBranches.keys)
        candidatePanelIds.formUnion(workspace.panelPullRequests.keys)
        // Only keep background polling panels whose current directory has already
        // proven to yield sidebar git metadata. Initial multi-attempt probes handle
        // startup races; this avoids polling non-repo directories forever.
        candidatePanelIds.formUnion(
            workspace.panels.keys.compactMap { panelId in
                guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: panelId) else {
                    return nil
                }
                let probeKey = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                guard workspaceGitTrackedDirectoryByKey[probeKey] == currentDirectory else {
                    return nil
                }
                return panelId
            }
        )

        if candidatePanelIds.isEmpty,
           let focusedPanelId = workspace.focusedPanelId,
           (workspace.gitBranch != nil || workspace.pullRequest != nil),
           gitProbeDirectory(for: workspace, panelId: focusedPanelId) != nil {
            candidatePanelIds.insert(focusedPanelId)
        }

        return Set(candidatePanelIds.filter { panelId in
            let probeKey = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
            return !activeProbeKeys.contains(probeKey)
        })
    }

    func gitProbeDirectory(for workspace: Workspace, panelId: UUID) -> String? {
        // Match the sidebar directory fallback chain so hidden/background panels can
        // still probe git metadata before OSC 7 has reported a live cwd.
        let rawDirectory = workspace.panelDirectories[panelId]
            ?? workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory
            ?? (workspace.focusedPanelId == panelId ? workspace.currentDirectory : nil)
        return rawDirectory.flatMap(normalizedWorkingDirectory)
    }

    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String = "initial"
    ) {
#if DEBUG
        didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
#endif
        guard let workspace = tabs.first(where: { $0.id == workspaceId }),
              !workspace.isRemoteWorkspace else {
            return
        }
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason,
            delays: Self.initialWorkspaceGitProbeDelays
        )
    }

    func scheduleWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        delays: [TimeInterval] = [0]
    ) {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: key)
            return
        }
        guard let workspace = tabs.first(where: { $0.id == workspaceId }),
              workspace.panels[panelId] != nil,
              let directory = gitProbeDirectory(for: workspace, panelId: panelId) else {
            return
        }

        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: delays,
            reason: reason
        )
    }

}
