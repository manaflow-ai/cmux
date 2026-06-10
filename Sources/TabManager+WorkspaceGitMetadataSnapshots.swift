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


// MARK: - Workspace Git Metadata Snapshots
extension TabManager {
    private func scheduleInitialWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String
    ) {
        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: Self.initialWorkspaceGitProbeDelays,
            reason: "initial"
        )
    }

    func scheduleWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        delays: [TimeInterval],
        reason: String
    ) {
        let normalizedDirectory = normalizeDirectory(directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        cancelWorkspaceGitProbeTask(for: key)
        if workspaceGitProbeStateByKey[key] == nil {
            workspaceGitProbeStateByKey[key] = .idle
        }

#if DEBUG
        cmuxDebugLog(
            "workspace.gitProbe.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) dir=\(normalizedDirectory) reason=\(reason)"
        )
#endif

        let clock = gitPollClock
        workspaceGitProbeTasksByKey[key] = Task { @MainActor [weak self] in
            // The retry delays are absolute offsets from scheduling time; walk
            // them as sequential gaps on the injected clock (bounded,
            // cancellable; cancellation replaces the old timer cancels).
            var previousDelay: TimeInterval = 0
            for (index, delay) in delays.enumerated() {
                let isLastAttempt = index == delays.count - 1
                do {
                    try await clock.sleep(for: .seconds(delay - previousDelay))
                } catch {
                    return
                }
                previousDelay = delay
                guard let self, !Task.isCancelled else { return }
                self.beginWorkspaceGitMetadataProbeAttempt(
                    probeKey: key,
                    expectedDirectory: normalizedDirectory,
                    isLastAttempt: isLastAttempt
                )
            }
        }
    }

    private func beginWorkspaceGitMetadataProbeAttempt(
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            workspaceGitProbeStateByKey[probeKey] = .idle
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "mobileHostDeferred",
                delays: [max(
                    Self.mobileHostBackgroundWorkDeferralInterval,
                    MobileHostRequestActivity.quietDelay(for: Self.mobileHostBackgroundWorkQuietInterval)
                )]
            )
            return
        }

        switch workspaceGitProbeStateByKey[probeKey] ?? .idle {
        case .idle:
            workspaceGitProbeStateByKey[probeKey] = .inFlight(rerunPending: false)
        case .inFlight:
            markWorkspaceGitProbeRerunPending(for: probeKey)
            return
        }

        enqueueWorkspaceGitMetadataSnapshotRequest(
            probeKey: probeKey,
            expectedDirectory: expectedDirectory,
            isLastAttempt: isLastAttempt
        )
    }

    private func enqueueWorkspaceGitMetadataSnapshotRequest(
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        let request = WorkspaceGitSnapshotProbeRequest(
            probeKey: probeKey,
            isLastAttempt: isLastAttempt
        )
        if let currentDirectory = workspaceGitSnapshotDirectoryByProbeKey[probeKey],
           currentDirectory != expectedDirectory {
            removeWorkspaceGitSnapshotRequest(for: probeKey)
        }
        workspaceGitSnapshotDirectoryByProbeKey[probeKey] = expectedDirectory
        if var requests = workspaceGitSnapshotRequestsByDirectory[expectedDirectory],
           let existingRequestIndex = requests.firstIndex(where: { $0.probeKey == probeKey }) {
            requests[existingRequestIndex] = request
            workspaceGitSnapshotRequestsByDirectory[expectedDirectory] = requests
        } else {
            workspaceGitSnapshotRequestsByDirectory[expectedDirectory, default: []].append(request)
        }
        guard workspaceGitSnapshotTasksByDirectory[expectedDirectory] == nil else {
#if DEBUG
            cmuxDebugLog(
                "workspace.gitProbe.joinSnapshot dir=\(expectedDirectory) " +
                "queued=\(workspaceGitSnapshotRequestsByDirectory[expectedDirectory]?.count ?? 0)"
            )
#endif
            return
        }

        let reader = workspaceGitMetadataReader
        workspaceGitSnapshotTasksByDirectory[expectedDirectory] = Task.detached(priority: .utility) { [weak self] in
            let didAcquirePermit = await WorkspaceGitMetadataProbeLimiter.shared.acquire()
            guard didAcquirePermit else { return }
            defer {
                Task {
                    await WorkspaceGitMetadataProbeLimiter.shared.release()
                }
            }

            guard !Task.isCancelled else { return }
            let snapshot = await Self.initialWorkspaceGitMetadataSnapshot(
                for: expectedDirectory,
                reader: reader
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.applyWorkspaceGitMetadataSnapshotBatch(
                    snapshot,
                    expectedDirectory: expectedDirectory
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataSnapshotBatch(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        expectedDirectory: String
    ) {
        workspaceGitSnapshotTasksByDirectory.removeValue(forKey: expectedDirectory)
        let requests = workspaceGitSnapshotRequestsByDirectory.removeValue(forKey: expectedDirectory) ?? []
        for request in requests {
            workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: request.probeKey)
            applyWorkspaceGitMetadataSnapshot(
                snapshot,
                probeKey: request.probeKey,
                expectedDirectory: expectedDirectory,
                isLastAttempt: request.isLastAttempt
            )
        }
    }

    private func removeWorkspaceGitSnapshotRequest(for key: WorkspaceGitProbeKey) {
        guard let directory = workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: key),
              var requests = workspaceGitSnapshotRequestsByDirectory[directory] else {
            return
        }
        requests.removeAll { $0.probeKey == key }
        if requests.isEmpty {
            workspaceGitSnapshotRequestsByDirectory.removeValue(forKey: directory)
            workspaceGitSnapshotTasksByDirectory.removeValue(forKey: directory)?.cancel()
        } else {
            workspaceGitSnapshotRequestsByDirectory[directory] = requests
        }
    }

    func cancelAllWorkspaceGitSnapshotTasks() {
        for task in workspaceGitSnapshotTasksByDirectory.values {
            task.cancel()
        }
        workspaceGitSnapshotTasksByDirectory.removeAll()
        workspaceGitSnapshotRequestsByDirectory.removeAll()
        workspaceGitSnapshotDirectoryByProbeKey.removeAll()
    }

    private func cancelWorkspaceGitProbeTask(for key: WorkspaceGitProbeKey) {
        workspaceGitProbeTasksByKey.removeValue(forKey: key)?.cancel()
    }

    func clearWorkspaceGitProbe(_ key: WorkspaceGitProbeKey) {
        removeWorkspaceGitSnapshotRequest(for: key)
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        workspaceGitCleanIndexSignatureByKey.removeValue(forKey: key)
        workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: key)
        workspaceGitHeadSignatureByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTask(for: key)
        stopWorkspaceGitMetadataWatcher(for: key)
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func finishWorkspaceGitProbeAttempt(_ key: WorkspaceGitProbeKey) {
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTask(for: key)
    }

    func clearWorkspaceGitMetadata(for key: WorkspaceGitProbeKey) {
        clearWorkspaceGitProbe(key)
        workspaceGitTrackedDirectoryByKey.removeValue(forKey: key)
        updateWorkspaceGitMetadataFallbackTimer()
        clearWorkspacePullRequestTracking(for: key)
        guard let workspace = tabs.first(where: { $0.id == key.workspaceId }) else {
            return
        }
        workspace.clearPanelGitBranch(panelId: key.panelId)
        workspace.clearPanelPullRequest(panelId: key.panelId)
    }

    func clearAllWorkspaceSidebarGitMetadata() {
        for workspace in tabs {
            workspace.clearSidebarGitMetadata()
        }
    }

    func clearAllWorkspaceSidebarPullRequestMetadata() {
        for workspace in tabs {
            workspace.clearSidebarPullRequestMetadata()
        }
    }

    func clearWorkspaceGitProbes(workspaceId: UUID) {
        let keys = Set(workspaceGitProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTasksByKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            clearWorkspaceGitProbe(key)
        }
        workspaceGitTrackedDirectoryByKey = workspaceGitTrackedDirectoryByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitCleanIndexSignatureByKey = workspaceGitCleanIndexSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitCleanIndexContentSignatureByKey = workspaceGitCleanIndexContentSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitHeadSignatureByKey = workspaceGitHeadSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        stopWorkspaceGitMetadataWatchers(workspaceId: workspaceId)
        updateWorkspaceGitMetadataFallbackTimer()
        clearWorkspacePullRequestTracking(workspaceId: workspaceId)
    }

    private func applyWorkspaceGitMetadataSnapshot(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        let wasInFlight: Bool = {
            if case .inFlight = workspaceGitProbeStateByKey[probeKey] { return true }
            return false
        }()
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            workspaceGitProbeStateByKey[probeKey] = .idle
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "mobileHostDeferred",
                delays: [max(
                    Self.mobileHostBackgroundWorkDeferralInterval,
                    MobileHostRequestActivity.quietDelay(for: Self.mobileHostBackgroundWorkQuietInterval)
                )]
            )
            return
        }
        let shouldTrackPullRequests = sidebarPullRequestPollingEnabled
        let resolvedPullRequest: SidebarPullRequestState? = {
            guard shouldTrackPullRequests else { return nil }
            guard case .resolved(let pullRequest) = snapshot.pullRequest else { return nil }
            return pullRequest
        }()
        let shouldTrackGitDirectory = snapshot.isRepository || resolvedPullRequest != nil
        let shouldFinishProbe = shouldStopWorkspaceGitMetadataRefresh(snapshot) || isLastAttempt
        let shouldStopTrackingGitDirectory = shouldFinishProbe && !shouldTrackGitDirectory
        var didClearProbe = false
        defer {
            if wasInFlight, !didClearProbe {
                let rerunPending = workspaceGitProbeRerunPending(for: probeKey)
                if rerunPending {
                    workspaceGitProbeStateByKey[probeKey] = .idle
                    if shouldFinishProbe {
                        cancelWorkspaceGitProbeTask(for: probeKey)
                    }
                    scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: probeKey.workspaceId,
                        panelId: probeKey.panelId,
                        reason: "rerunPending"
                    )
                } else if shouldStopTrackingGitDirectory {
                    clearWorkspaceGitProbe(probeKey)
                } else if shouldFinishProbe {
                    finishWorkspaceGitProbeAttempt(probeKey)
                } else {
                    workspaceGitProbeStateByKey[probeKey] = .idle
                }
            }
        }

        guard wasInFlight else { return }
        guard let workspace = tabs.first(where: { $0.id == probeKey.workspaceId }) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        guard workspace.panels[probeKey.panelId] != nil else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }

        guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: probeKey.panelId) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        if currentDirectory != expectedDirectory {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
#if DEBUG
            cmuxDebugLog(
                "workspace.gitProbe.skip workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
                "panel=\(probeKey.panelId.uuidString.prefix(5)) reason=directoryChanged " +
                "expected=\(expectedDirectory) current=\(currentDirectory)"
            )
#endif
            return
        }

        workspace.updatePanelDirectory(panelId: probeKey.panelId, directory: expectedDirectory)

        if shouldTrackGitDirectory {
            workspaceGitTrackedDirectoryByKey[probeKey] = expectedDirectory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: expectedDirectory)
        } else {
            workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
            stopWorkspaceGitMetadataWatcher(for: probeKey)
        }
        updateWorkspaceGitMetadataFallbackTimer()

        let nextBranch = snapshot.branch
        if let nextBranch {
            if let headSignature = snapshot.headSignature {
                if let previousHeadSignature = workspaceGitHeadSignatureByKey[probeKey],
                   previousHeadSignature != headSignature {
                    workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
                    workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
                }
                workspaceGitHeadSignatureByKey[probeKey] = headSignature
            } else {
                workspaceGitHeadSignatureByKey.removeValue(forKey: probeKey)
            }
            var isDirty = snapshot.isDirty
            if !isDirty,
               let indexSignature = snapshot.indexSignature,
               let cleanIndexSignature = workspaceGitCleanIndexSignatureByKey[probeKey],
               cleanIndexSignature != indexSignature {
                if let indexContentSignature = snapshot.indexContentSignature,
                   let cleanIndexContentSignature = workspaceGitCleanIndexContentSignatureByKey[probeKey],
                   cleanIndexContentSignature == indexContentSignature {
                    workspaceGitCleanIndexSignatureByKey[probeKey] = indexSignature
                } else {
                    isDirty = true
                }
            }
            workspace.updatePanelGitBranch(
                panelId: probeKey.panelId,
                branch: nextBranch,
                isDirty: isDirty
            )
            if !isDirty {
                if let indexSignature = snapshot.indexSignature {
                    workspaceGitCleanIndexSignatureByKey[probeKey] = indexSignature
                } else {
                    workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
                }
                if let indexContentSignature = snapshot.indexContentSignature {
                    workspaceGitCleanIndexContentSignatureByKey[probeKey] = indexContentSignature
                } else {
                    workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
                }
            }
        } else {
            workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
            workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
            workspaceGitHeadSignatureByKey.removeValue(forKey: probeKey)
            workspace.clearPanelGitBranch(panelId: probeKey.panelId)
        }

        switch snapshot.pullRequest {
        case .resolved(let pullRequest):
            if shouldTrackPullRequests {
                workspace.updatePanelPullRequest(
                    panelId: probeKey.panelId,
                    number: pullRequest.number,
                    label: pullRequest.label,
                    url: pullRequest.url,
                    status: pullRequest.status,
                    branch: pullRequest.branch,
                    isStale: false
                )
            } else if workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
        case .notFound:
            if workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
        case .deferred, .unsupportedRepository, .transientFailure:
            if !shouldTrackPullRequests, workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
            break
        }

        if snapshot.branch != nil, shouldTrackPullRequests {
            scheduleWorkspacePullRequestRefresh(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "localGitProbe"
            )
        }

#if DEBUG
        let branchLabel = snapshot.branch ?? "none"
        let prLabel: String = {
            switch snapshot.pullRequest {
            case .deferred:
                return "deferred"
            case .unsupportedRepository:
                return "unsupported"
            case .notFound:
                return "none"
            case .transientFailure:
                return "transientFailure"
            case .resolved(let pullRequest):
                return "#\(pullRequest.number):\(pullRequest.status.rawValue)"
            }
        }()
        cmuxDebugLog(
            "workspace.gitProbe.apply workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
            "panel=\(probeKey.panelId.uuidString.prefix(5)) branch=\(branchLabel) dirty=\(snapshot.isDirty ? 1 : 0) " +
            "pr=\(prLabel)"
        )
#endif
    }

    private func shouldStopWorkspaceGitMetadataRefresh(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot
    ) -> Bool {
        if snapshot.isRepository {
            return false
        }
        switch snapshot.pullRequest {
        case .deferred, .transientFailure:
            return false
        case .unsupportedRepository, .notFound, .resolved:
            return true
        }
    }

    private nonisolated static func initialWorkspaceGitMetadataSnapshot(
        for directory: String,
        reader: any WorkspaceGitMetadataReading
    ) async -> InitialWorkspaceGitMetadataSnapshot {
        let metadata = await reader.workspaceMetadata(for: directory)
        guard metadata.isRepository else {
            return InitialWorkspaceGitMetadataSnapshot(
                isRepository: false,
                branch: nil,
                isDirty: false,
                indexSignature: nil,
                indexContentSignature: nil,
                headSignature: nil,
                pullRequest: .notFound
            )
        }

        let branch = GitMetadataService.normalizedBranchName(metadata.branch)
        return InitialWorkspaceGitMetadataSnapshot(
            isRepository: true,
            branch: branch,
            isDirty: metadata.isDirty,
            indexSignature: metadata.indexSignature,
            indexContentSignature: metadata.indexContentSignature,
            headSignature: metadata.headSignature,
            pullRequest: branch == nil ? .notFound : .deferred
        )
    }

}
