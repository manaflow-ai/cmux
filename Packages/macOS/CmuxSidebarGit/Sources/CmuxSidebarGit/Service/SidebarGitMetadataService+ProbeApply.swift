internal import Foundation
internal import CmuxGit

// MARK: - Probe snapshot application

extension SidebarGitMetadataService {
    func applyWorkspaceGitMetadataSnapshot(
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
        if let nextBranch,
           shouldTrackPullRequests {
            pullRequestProbing.seedWorkspacePullRequestRefreshIfNeeded(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                directory: expectedDirectory,
                branch: nextBranch,
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
