public import Foundation
internal import CmuxGit

// MARK: - Probe scheduling, the per-directory snapshot pipeline, and apply.

extension SidebarGitMetadataService {
    public func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {
        guard host?.shouldSkipLocalGitMetadata(workspaceId: workspaceId, panelId: panelId) != true else {
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
        delays: [TimeInterval] = [0],
        snapshotRequest: GitTrackedChangesSnapshotRequest? = nil
    ) {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard let host else { return }
        guard !host.shouldSkipLocalGitMetadata(workspaceId: workspaceId, panelId: panelId) else { return }
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: key)
            return
        }
        guard host.panelExists(workspaceId: workspaceId, panelId: panelId),
              let directory = host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId) else {
            return
        }

        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: delays,
            reason: reason,
            snapshotRequest: snapshotRequest
        )
    }

    private func scheduleWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        delays: [TimeInterval],
        reason: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) {
        let normalizedDirectory = directory.normalizedGitProbeDirectory
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let taskContext = WorkspaceGitSnapshotTaskContext(
            snapshotRequest: snapshotRequestForSnapshot(
                directory: normalizedDirectory,
                reason: reason,
                fallbackRequest: snapshotRequest
            )
        )
        supersedeWorkspaceGitSnapshotTask(
            directory: normalizedDirectory,
            with: taskContext
        )
        cancelWorkspaceGitProbeTask(for: key)
        if workspaceGitProbeStateByKey[key] == nil {
            workspaceGitProbeStateByKey[key] = .idle
        }

#if DEBUG
        debugLog(
            "workspace.gitProbe.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) dir=\(normalizedDirectory) reason=\(reason)"
        )
#endif

        let clock = clock
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
                    isLastAttempt: isLastAttempt,
                    taskContext: taskContext
                )
            }
        }
    }

    private func beginWorkspaceGitMetadataProbeAttempt(
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool,
        taskContext: WorkspaceGitSnapshotTaskContext
    ) {
        guard host?.mobileHostHasRecentActivity(within: mobileHostDeferral.quietInterval) != true else {
            workspaceGitProbeStateByKey[probeKey] = .idle
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "mobileHostDeferred",
                delays: [max(
                    mobileHostDeferral.deferralInterval,
                    host?.mobileHostQuietDelay(for: mobileHostDeferral.quietInterval) ?? 0
                )]
            )
            return
        }

        switch workspaceGitProbeStateByKey[probeKey] ?? .idle {
        case .idle:
            workspaceGitProbeStateByKey[probeKey] = .inFlight(rerunPending: false)
        case .inFlight:
            markWorkspaceGitProbeRerunPending(for: probeKey)
            supersedeWorkspaceGitSnapshotTask(
                directory: expectedDirectory,
                with: taskContext
            )
            return
        }

        enqueueWorkspaceGitMetadataSnapshotRequest(
            probeKey: probeKey,
            expectedDirectory: expectedDirectory,
            isLastAttempt: isLastAttempt,
            taskContext: taskContext
        )
    }

    private func enqueueWorkspaceGitMetadataSnapshotRequest(
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool,
        taskContext: WorkspaceGitSnapshotTaskContext
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
        workspaceGitSnapshotRequestsByDirectory[expectedDirectory, default: [:]][probeKey] = request
        guard workspaceGitSnapshotTasksByDirectory[expectedDirectory] == nil else {
            if workspaceGitSnapshotTaskContextByDirectory[expectedDirectory] != taskContext {
                supersedeWorkspaceGitSnapshotTask(
                    directory: expectedDirectory,
                    with: taskContext
                )
            }
#if DEBUG
            debugLog(
                "workspace.gitProbe.joinSnapshot dir=\(expectedDirectory) " +
                "queued=\(workspaceGitSnapshotRequestsByDirectory[expectedDirectory]?.count ?? 0)"
            )
#endif
            return
        }

        let reader = workspaceGitMetadataReader
        let probeLimiter = probeLimiter
        let taskID = UUID()
        workspaceGitSnapshotTaskContextByDirectory[expectedDirectory] = taskContext
        workspaceGitSnapshotTaskIDByDirectory[expectedDirectory] = taskID
        workspaceGitSnapshotTasksByDirectory[expectedDirectory] = Task.detached(priority: .utility) { [weak self] in
            let didAcquirePermit = await probeLimiter.acquire()
            guard didAcquirePermit else { return }
            defer {
                Task {
                    await probeLimiter.release()
                }
            }

            guard !Task.isCancelled else { return }
            let snapshot = await InitialWorkspaceGitMetadataSnapshot(
                probing: expectedDirectory,
                reader: reader,
                snapshotRequest: taskContext.snapshotRequest
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.enqueueWorkspaceGitMetadataSnapshotBatch(
                    snapshot,
                    taskID: taskID,
                    expectedDirectory: expectedDirectory
                )
            }
        }
    }

    private func enqueueWorkspaceGitMetadataSnapshotBatch(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        taskID: UUID,
        expectedDirectory: String
    ) {
        let apply = WorkspaceGitSnapshotApply(taskID: taskID, snapshot: snapshot)
        workspaceGitSnapshotApplyBatcher.submit(apply, for: expectedDirectory) { [weak self] snapshots in
            guard let self else { return }
            // Stable ordering keeps state-machine transitions and test traces
            // deterministic when multiple repositories finish in one frame.
            for directory in snapshots.keys.sorted() {
                guard let apply = snapshots[directory] else { continue }
                self.applyWorkspaceGitMetadataSnapshotBatch(
                    apply.snapshot,
                    taskID: apply.taskID,
                    expectedDirectory: directory
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataSnapshotBatch(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        taskID: UUID,
        expectedDirectory: String
    ) {
        guard workspaceGitSnapshotTaskIDByDirectory[expectedDirectory] == taskID else {
            return
        }
        let taskWasSuperseded = workspaceGitSupersededSnapshotTaskIDs.remove(taskID) != nil
        let wasSuperseded = taskWasSuperseded || !snapshot.isCurrent
        let pendingContext = workspaceGitSnapshotPendingContextByDirectory.removeValue(
            forKey: expectedDirectory
        )
        workspaceGitSnapshotTasksByDirectory.removeValue(forKey: expectedDirectory)
        workspaceGitSnapshotTaskContextByDirectory.removeValue(forKey: expectedDirectory)
        workspaceGitSnapshotTaskIDByDirectory.removeValue(forKey: expectedDirectory)
        let requests = workspaceGitSnapshotRequestsByDirectory.removeValue(forKey: expectedDirectory) ?? [:]
        if wasSuperseded {
            for request in requests.values {
                workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: request.probeKey)
                guard case .inFlight = workspaceGitProbeStateByKey[request.probeKey] else {
                    continue
                }
                workspaceGitProbeStateByKey[request.probeKey] = .idle
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: request.probeKey.workspaceId,
                    panelId: request.probeKey.panelId,
                    reason: "supersededSnapshot",
                    snapshotRequest: pendingContext?.snapshotRequest
                )
            }
            return
        }
        for request in requests.values {
            workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: request.probeKey)
            applyWorkspaceGitMetadataSnapshot(
                snapshot,
                probeKey: request.probeKey,
                expectedDirectory: expectedDirectory,
                isLastAttempt: request.isLastAttempt
            )
        }
    }

    func cancelWorkspaceGitProbeTask(for key: WorkspaceGitProbeKey) {
        workspaceGitProbeTasksByKey.removeValue(forKey: key)?.cancel()
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
        guard host?.mobileHostHasRecentActivity(within: mobileHostDeferral.quietInterval) != true else {
            workspaceGitProbeStateByKey[probeKey] = .idle
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "mobileHostDeferred",
                delays: [max(
                    mobileHostDeferral.deferralInterval,
                    host?.mobileHostQuietDelay(for: mobileHostDeferral.quietInterval) ?? 0
                )]
            )
            return
        }
        let shouldTrackPullRequests = sidebarPullRequestPollingEnabled
        let resolvedPullRequest: SidebarPullRequestBadge? = {
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
        guard let host, host.workspaceExists(probeKey.workspaceId) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        guard host.panelExists(workspaceId: probeKey.workspaceId, panelId: probeKey.panelId) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        if host.shouldSkipLocalGitMetadata(workspaceId: probeKey.workspaceId, panelId: probeKey.panelId) {
            clearWorkspaceGitProbeTracking(for: probeKey)
            didClearProbe = true
            return
        }

        guard let currentDirectory = host.gitProbeDirectory(
            workspaceId: probeKey.workspaceId,
            panelId: probeKey.panelId
        ) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        if currentDirectory != expectedDirectory {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
#if DEBUG
            debugLog(
                "workspace.gitProbe.skip workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
                "panel=\(probeKey.panelId.uuidString.prefix(5)) reason=directoryChanged " +
                "expected=\(expectedDirectory) current=\(currentDirectory)"
            )
#endif
            return
        }

        host.updatePanelDirectory(
            workspaceId: probeKey.workspaceId,
            panelId: probeKey.panelId,
            directory: expectedDirectory,
            displayLabel: nil
        )

        if shouldTrackGitDirectory {
            workspaceGitTrackedDirectoryByKey[probeKey] = expectedDirectory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: expectedDirectory)
        } else {
            workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
            stopWorkspaceGitMetadataWatcher(for: probeKey)
        }
        updateWorkspaceGitMetadataFallbackTimer()

        let previousBranchState = host.panelGitBranch(
            workspaceId: probeKey.workspaceId,
            panelId: probeKey.panelId
        )
        let previousPullRequestBadge = host.panelPullRequestBadge(
            workspaceId: probeKey.workspaceId,
            panelId: probeKey.panelId
        )
        var didApplyMaterialSidebarGitChange = false
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
            let nextBranchState = SidebarPanelGitBranch(branch: nextBranch, isDirty: isDirty)
            didApplyMaterialSidebarGitChange = previousBranchState != nextBranchState
            host.updatePanelGitBranch(
                workspaceId: probeKey.workspaceId,
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
            didApplyMaterialSidebarGitChange = previousBranchState != nil
            host.clearPanelGitBranch(workspaceId: probeKey.workspaceId, panelId: probeKey.panelId)
        }

        switch snapshot.pullRequest {
        case .resolved(let pullRequest):
            if shouldTrackPullRequests {
                let nextBadge = SidebarPullRequestBadge(
                    number: pullRequest.number,
                    label: pullRequest.label,
                    url: pullRequest.url,
                    status: pullRequest.status,
                    branch: pullRequest.branch,
                    isStale: false
                )
                didApplyMaterialSidebarGitChange = didApplyMaterialSidebarGitChange
                    || previousPullRequestBadge != nextBadge
                host.updatePanelPullRequest(
                    workspaceId: probeKey.workspaceId,
                    panelId: probeKey.panelId,
                    badge: nextBadge
                )
            } else if host.panelPullRequestBadge(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId
            ) != nil {
                didApplyMaterialSidebarGitChange = true
                host.clearPanelPullRequest(workspaceId: probeKey.workspaceId, panelId: probeKey.panelId)
            }
        case .notFound:
            if host.panelPullRequestBadge(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId
            ) != nil {
                didApplyMaterialSidebarGitChange = true
                host.clearPanelPullRequest(workspaceId: probeKey.workspaceId, panelId: probeKey.panelId)
            }
        case .deferred, .unsupportedRepository, .transientFailure:
            if !shouldTrackPullRequests,
               host.panelPullRequestBadge(
                   workspaceId: probeKey.workspaceId,
                   panelId: probeKey.panelId
               ) != nil {
                didApplyMaterialSidebarGitChange = true
                host.clearPanelPullRequest(workspaceId: probeKey.workspaceId, panelId: probeKey.panelId)
            }
        }
        let isPullRequestRefreshTracked = pullRequestProbing
            .workspacePullRequestTrackedPanelIds(workspaceId: probeKey.workspaceId)
            .contains(probeKey.panelId)
        if let nextBranch,
           shouldTrackPullRequests,
           previousBranchState?.branch != nextBranch || !isPullRequestRefreshTracked {
            pullRequestProbing.scheduleWorkspacePullRequestRefresh(
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
        debugLog(
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
}
