public import Foundation
import CmuxGit

// MARK: - Applying refresh results, poll-deadline math, and tracking bookkeeping.

extension PullRequestPollService {
    // MARK: Apply

    func applyWorkspacePullRequestRefreshResults(
        _ results: [WorkspacePullRequestRefreshResult],
        repoResults: [String: WorkspacePullRequestRepoFetchResult],
        requestedKeys: [WorkspaceGitProbeKey],
        requestedSourceByKey: [WorkspaceGitProbeKey: SourceIdentity] = [:],
        now: Date,
        reason: String
    ) {
        runtimeMetricsRecorder.recordPullRequestMainActorApplyEntered()
        guard let host else { return }
        guard !host.mobileHostHasRecentActivity(within: mobileHostDeferral.quietInterval) else {
            workspacePullRequestRefreshTask = nil
            for key in requestedKeys {
                workspacePullRequestProbeStateByKey[key] = .idle
                workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(mobileHostDeferral.quietInterval)
            }
            deferWorkspacePullRequestRefreshForMobileHost()
            return
        }
        guard sidebarPullRequestPollingEnabled else {
            resetWorkspacePullRequestRefreshState()
            host.clearAllSidebarPullRequestMetadata()
            return
        }

        for (repoSlug, repoResult) in repoResults {
            guard case .success(let cacheEntry, let usedCache, _) = repoResult,
                  !usedCache else {
                continue
            }
            workspacePullRequestRepoCacheBySlug[repoSlug] = cacheEntry
        }

        let requestedKeySet = Set(requestedKeys)
        let resultsByKey = Dictionary(
            uniqueKeysWithValues: results.map {
                (WorkspaceGitProbeKey(workspaceId: $0.workspaceId, panelId: $0.panelId), $0)
            }
        )
        var needsFollowUpPass = false

        defer {
            let pendingSeedRefresh = takePendingSeedRefresh()
            let pendingRefreshRequest = takePendingRefreshRequest()
            if needsFollowUpPass || pendingSeedRefresh != nil || pendingRefreshRequest != nil {
                let shouldBypassRepoCache =
                    pendingSeedRefresh?.shouldBypassRepoCache == true
                    || pendingRefreshRequest?.shouldBypassRepoCache == true
                startWorkspacePullRequestFollowUp(
                    reason: "\(pendingRefreshRequest?.reason ?? reason).followUp",
                    shouldBypassRepoCache: shouldBypassRepoCache
                )
            }
        }

        for key in requestedKeys {
            if host.shouldSkipLocalGitMetadata(workspaceId: key.workspaceId, panelId: key.panelId) {
                clearWorkspacePullRequestTracking(for: key)
                continue
            }

            let rerunPending = workspacePullRequestProbeRerunPending(for: key)
            workspacePullRequestProbeStateByKey[key] = .idle
            if rerunPending {
                workspacePullRequestNextPollAtByKey[key] = .distantPast
                needsFollowUpPass = true
            }

            if let requestedSource = requestedSourceByKey[key],
               workspacePullRequestSourceByKey[key] != requestedSource {
                SidebarGitMetadataService.recordStaleApply()
                if let currentSource = workspacePullRequestSourceByKey[key] {
                    if PullRequestProbeService.shouldSkipLookup(branch: currentSource.branch) {
                        clearWorkspacePullRequestTracking(for: key, preservingSource: true)
                    } else {
                        workspacePullRequestNextPollAtByKey[key] = .distantPast
                        needsFollowUpPass = true
                    }
                } else {
                    clearWorkspacePullRequestTracking(for: key)
                }
                continue
            }

            guard requestedKeySet.contains(key),
                  let result = resultsByKey[key] else {
                continue
            }

            if rerunPending,
               (workspacePullRequestPendingSeedRefresh?.shouldBypassRepoCache == true ||
                   workspacePullRequestPendingRefreshRequest?.shouldBypassRepoCache == true),
               result.usedCachedRepoData {
                continue
            }

            guard host.panelExists(workspaceId: result.workspaceId, panelId: result.panelId) else {
                clearWorkspacePullRequestTracking(for: key)
                continue
            }

            let priorPullRequest = host.panelPullRequestBadge(
                workspaceId: result.workspaceId,
                panelId: result.panelId
            )
            let countsAsTerminalSweep = priorPullRequest.map { $0.status != .open } ?? false

            switch result.resolution {
            case .resolved(let resolvedPullRequest):
                workspacePullRequestTransientFailureCountByKey[key] = 0
                guard let status = PullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
                      let url = URL(string: resolvedPullRequest.urlString) else {
                    continue
                }
                host.updatePanelPullRequest(
                    workspaceId: result.workspaceId,
                    panelId: result.panelId,
                    badge: SidebarPullRequestBadge(
                        number: resolvedPullRequest.number,
                        label: "PR",
                        url: url,
                        status: status,
                        branch: resolvedPullRequest.branch,
                        isStale: false
                    )
                )
                let resolvedBranch = GitMetadataService.normalizedBranchName(resolvedPullRequest.branch)
                let projectedBranch = GitMetadataService.normalizedBranchName(
                    host.panelGitBranch(workspaceId: result.workspaceId, panelId: result.panelId)?.branch
                )
                // Nudge only while git metadata watching is on: with watching
                // disabled the probe scheduler clears the panel's branch AND
                // the badge this pass just applied (there is also no branch
                // projection to heal).
                if resolvedBranch != projectedBranch, host.isGitMetadataWatchEnabled {
                    host.schedulePanelGitMetadataProbe(
                        workspaceId: result.workspaceId,
                        panelId: result.panelId,
                        reason: "pullRequestBranchMismatch"
                    )
#if DEBUG
                    debugLog(
                        "workspace.prRefresh.branchProjectionMismatch " +
                        "workspace=\(result.workspaceId.uuidString.prefix(5)) " +
                        "panel=\(result.panelId.uuidString.prefix(5)) " +
                        "resolved=\(resolvedPullRequest.branch) " +
                        "projected=\(projectedBranch ?? "nil")"
                    )
#endif
                }
            case .notFound:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if host.panelPullRequestBadge(workspaceId: result.workspaceId, panelId: result.panelId) != nil {
                    host.clearPanelPullRequest(workspaceId: result.workspaceId, panelId: result.panelId)
                }
            case .unsupportedRepository:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if host.panelPullRequestBadge(workspaceId: result.workspaceId, panelId: result.panelId) != nil {
                    host.clearPanelPullRequest(workspaceId: result.workspaceId, panelId: result.panelId)
                }
            case .transientFailure:
                let nextFailureCount = (workspacePullRequestTransientFailureCountByKey[key] ?? 0) + 1
                workspacePullRequestTransientFailureCountByKey[key] = nextFailureCount
                if nextFailureCount >= 3,
                   let currentPullRequest = host.panelPullRequestBadge(
                       workspaceId: result.workspaceId,
                       panelId: result.panelId
                   ) {
                    host.updatePanelPullRequest(
                        workspaceId: result.workspaceId,
                        panelId: result.panelId,
                        badge: SidebarPullRequestBadge(
                            number: currentPullRequest.number,
                            label: currentPullRequest.label,
                            url: currentPullRequest.url,
                            status: currentPullRequest.status,
                            branch: currentPullRequest.branch,
                            isStale: true
                        )
                    )
                }
            }

            scheduleNextWorkspacePullRequestPoll(
                key: key,
                workspaceId: result.workspaceId,
                panelId: result.panelId,
                now: now,
                resolution: result.resolution,
                countsAsTerminalSweep: countsAsTerminalSweep
            )
            if rerunPending {
                workspacePullRequestNextPollAtByKey[key] = .distantPast
            }

#if DEBUG
            let label: String = {
                switch result.resolution {
                case .unsupportedRepository:
                    return "unsupported"
                case .notFound:
                    return "none"
                case .transientFailure:
                    return "transientFailure"
                case .resolved(let resolvedPullRequest):
                    return "#\(resolvedPullRequest.number):\(resolvedPullRequest.statusRawValue)"
                }
            }()
            debugLog(
                "workspace.prRefresh.apply workspace=\(result.workspaceId.uuidString.prefix(5)) " +
                "panel=\(result.panelId.uuidString.prefix(5)) result=\(label) reason=\(reason)"
            )
#endif
        }

        updateWorkspacePullRequestPollTimer()
    }

    func scheduleNextWorkspacePullRequestPoll(
        key: WorkspaceGitProbeKey,
        workspaceId: UUID,
        panelId: UUID,
        now: Date,
        resolution: WorkspacePullRequestRefreshResult.Resolution,
        countsAsTerminalSweep: Bool
    ) {
        if countsAsTerminalSweep {
            workspacePullRequestLastTerminalStateRefreshAtByKey[key] = now
        }

        if case .resolved(let resolvedPullRequest) = resolution,
           let status = PullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
           status != .open {
            workspacePullRequestLastTerminalStateRefreshAtByKey[key] = now
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(PullRequestProbeService.terminalStateSweepInterval)
            return
        }

        if case .transientFailure = resolution,
           workspacePullRequestLastTerminalStateRefreshAtByKey[key] != nil {
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(PullRequestProbeService.terminalStateSweepInterval)
            return
        }

        if case .unsupportedRepository = resolution {
            workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.jitteredPollInterval(base: Self.backgroundPollInterval))
            return
        }

        workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
        let baseInterval = (host?.isSelectedFocusedPanel(workspaceId: workspaceId, panelId: panelId) ?? false)
            ? Self.selectedPollInterval
            : Self.backgroundPollInterval
        workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.jitteredPollInterval(base: baseInterval))
    }

    // MARK: Tracking bookkeeping

    func pruneWorkspacePullRequestTracking(validKeys: Set<WorkspaceGitProbeKey>) {
        if workspacePullRequestProbeStateByKey.contains(where: { key, state in
            guard !validKeys.contains(key) else { return false }
            if case .inFlight = state { return true }
            return false
        }) {
            workspacePullRequestRefreshAuthority?.invalidate()
        }
        workspacePullRequestSourceByKey = workspacePullRequestSourceByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestBypassRepoCacheKeys.formIntersection(validKeys)
        workspacePullRequestNextPollAtByKey = workspacePullRequestNextPollAtByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestProbeStateByKey = workspacePullRequestProbeStateByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestLastTerminalStateRefreshAtByKey = workspacePullRequestLastTerminalStateRefreshAtByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestTransientFailureCountByKey = workspacePullRequestTransientFailureCountByKey.filter { validKeys.contains($0.key) }
        let repoCacheCutoff = Date().addingTimeInterval(-Self.workspacePullRequestRepoCachePruneLifetime)
        workspacePullRequestRepoCacheBySlug = workspacePullRequestRepoCacheBySlug.filter {
            $0.value.fetchedAt >= repoCacheCutoff
        }
        updateWorkspacePullRequestPollTimer()
    }

    func clearWorkspacePullRequestTracking(
        for key: WorkspaceGitProbeKey,
        preservingSource: Bool = false
    ) {
        if case .inFlight = workspacePullRequestProbeStateByKey[key] {
            workspacePullRequestRefreshAuthority?.invalidate()
        }
        if !preservingSource {
            workspacePullRequestSourceByKey.removeValue(forKey: key)
        }
        workspacePullRequestBypassRepoCacheKeys.remove(key)
        workspacePullRequestNextPollAtByKey.removeValue(forKey: key)
        workspacePullRequestProbeStateByKey.removeValue(forKey: key)
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
        workspacePullRequestTransientFailureCountByKey.removeValue(forKey: key)
        updateWorkspacePullRequestPollTimer()
    }

    public func clearWorkspacePullRequestTracking(workspaceId: UUID, panelId: UUID) {
        clearWorkspacePullRequestTracking(
            for: WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        )
    }

    public func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        if workspacePullRequestProbeStateByKey.contains(where: { key, state in
            guard key.workspaceId == workspaceId else { return false }
            if case .inFlight = state { return true }
            return false
        }) {
            workspacePullRequestRefreshAuthority?.invalidate()
        }
        workspacePullRequestSourceByKey = workspacePullRequestSourceByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestBypassRepoCacheKeys = workspacePullRequestBypassRepoCacheKeys.filter {
            $0.workspaceId != workspaceId
        }
        workspacePullRequestNextPollAtByKey = workspacePullRequestNextPollAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestProbeStateByKey = workspacePullRequestProbeStateByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestLastTerminalStateRefreshAtByKey = workspacePullRequestLastTerminalStateRefreshAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestTransientFailureCountByKey = workspacePullRequestTransientFailureCountByKey.filter { $0.key.workspaceId != workspaceId }
        updateWorkspacePullRequestPollTimer()
    }

    func clearWorkspacePullRequestMetadata(for key: WorkspaceGitProbeKey) {
        clearWorkspacePullRequestTracking(for: key)
        guard let host, host.workspaceExists(key.workspaceId) else {
            return
        }
        host.clearPanelPullRequest(workspaceId: key.workspaceId, panelId: key.panelId)
    }

    public func clearWorkspacePullRequestMetadata(workspaceId: UUID, panelId: UUID) {
        clearWorkspacePullRequestMetadata(
            for: WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        )
    }

    public func resetWorkspacePullRequestRefreshState() {
        takePendingSeedRefresh()
        workspacePullRequestRefreshAuthority?.invalidate()
        workspacePullRequestRefreshAuthority = nil
        workspacePullRequestRefreshTask?.cancel()
        workspacePullRequestRefreshTask = nil
        workspacePullRequestProbeStateByKey.removeAll()
        workspacePullRequestNextPollAtByKey.removeAll()
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeAll()
        workspacePullRequestTransientFailureCountByKey.removeAll()
        workspacePullRequestRepoCacheBySlug.removeAll()
        workspacePullRequestSourceByKey.removeAll()
        workspacePullRequestBypassRepoCacheKeys.removeAll()
        workspacePullRequestPendingRefreshRequest = nil
        updateWorkspacePullRequestPollTimer()
    }

    func startWorkspacePullRequestFollowUp(
        reason: String,
        shouldBypassRepoCache: Bool
    ) {
        runtimeMetricsRecorder.recordPullRequestFollowUpStarted()
        refreshTrackedWorkspacePullRequestsIfNeeded(
            reason: reason,
            allowCachedResultsOverride: shouldBypassRepoCache ? false : nil
        )
    }

    // MARK: Rerun flags

    func markWorkspacePullRequestProbeRerunPending(
        for key: WorkspaceGitProbeKey,
        reason: String,
        bypassRepoCache: Bool
    ) {
        // A rerun means the active result no longer has mutation authority.
        // Invalidate synchronously so detached completion can reject it before
        // hopping to the main actor.
        workspacePullRequestRefreshAuthority?.invalidate()
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key],
              !rerunPending else {
            if bypassRepoCache {
                queueWorkspacePullRequestRefreshFollowUp(
                    reason: reason,
                    shouldBypassRepoCache: true
                )
            }
            return
        }
        workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: true)
        if bypassRepoCache {
            queueWorkspacePullRequestRefreshFollowUp(
                reason: reason,
                shouldBypassRepoCache: true
            )
        }
    }

    func workspacePullRequestProbeRerunPending(for key: WorkspaceGitProbeKey) -> Bool {
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key] else {
            return false
        }
        return rerunPending
    }

    nonisolated static func jitteredPollInterval(base: TimeInterval) -> TimeInterval {
        let jitter = base * Self.workspacePullRequestPollJitterFraction
        return base + Double.random(in: -jitter...jitter)
    }
}
