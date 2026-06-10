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


// MARK: - Workspace Pull Request Polling
extension TabManager {
    func updateWorkspacePullRequestPollTimer() {
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil

        guard sidebarPullRequestPollingEnabled,
              workspacePullRequestRefreshTask == nil,
              let nextPollAt = workspacePullRequestNextPollAtByKey.values.min() else {
            return
        }

        let delay = max(0.25, nextPollAt.timeIntervalSinceNow)
        let clock = gitPollClock
        workspacePullRequestPollTask = Task { @MainActor [weak self] in
            // Bounded, cancellable poll deadline on the injected clock;
            // re-arming cancels the previous task.
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        }
    }

    /// Reschedules the workspace pull-request refresh after the paired mobile
    /// host goes quiet, so background polling does not contend with active
    /// mobile-host request traffic. Re-arming cancels the previous deadline.
    private func deferWorkspacePullRequestRefreshForMobileHost() {
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil

        let quietDelay = MobileHostRequestActivity.quietDelay(
            for: Self.mobileHostBackgroundWorkQuietInterval
        )
        let delay = max(Self.mobileHostBackgroundWorkDeferralInterval, quietDelay)
        let clock = gitPollClock
        workspacePullRequestPollTask = Task { @MainActor [weak self] in
            // Bounded, cancellable mobile-host deferral on the injected clock;
            // re-arming cancels the previous task.
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "mobileHostDeferred")
        }
    }

    func refreshTrackedWorkspacePullRequestsIfNeeded(
        reason: String,
        allowCachedResultsOverride: Bool? = nil
    ) {
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            deferWorkspacePullRequestRefreshForMobileHost()
            return
        }
        guard sidebarPullRequestPollingEnabled else {
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarPullRequestMetadata()
            return
        }

        let now = Date()
        var candidateSeeds: [WorkspacePullRequestCandidateSeed] = []
        var requestedKeys: [WorkspaceGitProbeKey] = []
        var validKeys: Set<WorkspaceGitProbeKey> = []

        for workspace in tabs {
            for panelId in Set(workspace.panelGitBranches.keys).union(workspace.panelPullRequests.keys) {
                let key = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                validKeys.insert(key)
                let branch = GitMetadataService.normalizedBranchName(
                    workspace.panelGitBranches[panelId]?.branch
                        ?? workspace.panelPullRequests[panelId]?.branch
                )
                guard let branch else {
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                if PullRequestProbeService.shouldSkipLookup(branch: branch) {
                    workspace.clearPanelPullRequest(panelId: panelId)
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                guard shouldRefreshWorkspacePullRequest(
                    key: key,
                    now: now,
                    currentPullRequest: workspace.panelPullRequests[panelId]
                ) else {
                    continue
                }

                if case .inFlight = workspacePullRequestProbeStateByKey[key] {
                    markWorkspacePullRequestProbeRerunPending(
                        for: key,
                        bypassRepoCache: !PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
                    )
                    continue
                }

                let candidateSeed = workspacePullRequestCandidateSeed(
                    workspace: workspace,
                    panelId: panelId,
                    branch: branch
                )
                candidateSeeds.append(candidateSeed)
                requestedKeys.append(key)
            }
        }

        pruneWorkspacePullRequestTracking(validKeys: validKeys)
        if candidateSeeds.count > Self.workspacePullRequestRefreshBatchLimit {
            candidateSeeds = Array(candidateSeeds.prefix(Self.workspacePullRequestRefreshBatchLimit))
            requestedKeys = Array(requestedKeys.prefix(Self.workspacePullRequestRefreshBatchLimit))
        }
        guard workspacePullRequestRefreshTask == nil else {
            updateWorkspacePullRequestPollTimer()
            return
        }
        guard !candidateSeeds.isEmpty else {
            updateWorkspacePullRequestPollTimer()
            return
        }
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil
        for key in requestedKeys {
            workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: false)
        }

        let cacheBySlug = workspacePullRequestRepoCacheBySlug
        let allowCachedResults = allowCachedResultsOverride
            ?? PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
        let gitMetadataService = gitMetadataService
        let pullRequestProbeService = pullRequestProbeService
        workspacePullRequestRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let candidateResolution = await pullRequestProbeService.resolveCandidateSeeds(
                candidateSeeds,
                gitMetadata: gitMetadataService
            )
            guard !Task.isCancelled else { return }
            let repoResults = await pullRequestProbeService.fetchRepoResults(
                repoDirectoriesBySlug: candidateResolution.repoDirectoriesBySlug,
                candidateBranchesByRepo: candidateResolution.candidateBranchesByRepo,
                cacheBySlug: cacheBySlug,
                now: now,
                allowCachedResults: allowCachedResults
            )
            let results = PullRequestProbeService.resolveRefreshResults(
                candidates: candidateResolution.candidates,
                repoResults: repoResults
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.workspacePullRequestRefreshTask = nil
                self.applyWorkspacePullRequestRefreshResults(
                    results,
                    repoResults: repoResults,
                    requestedKeys: requestedKeys,
                    now: Date(),
                    reason: reason
                )
            }
        }
    }

    private func shouldRefreshWorkspacePullRequest(
        key: WorkspaceGitProbeKey,
        now: Date,
        currentPullRequest: SidebarPullRequestState?
    ) -> Bool {
        PullRequestProbeService.shouldRefresh(
            now: now,
            nextPollAt: workspacePullRequestNextPollAtByKey[key],
            lastTerminalStateRefreshAt: workspacePullRequestLastTerminalStateRefreshAtByKey[key],
            // Raw values are shared between the app and package status enums.
            currentStatus: currentPullRequest.flatMap { PullRequestStatus(rawValue: $0.status.rawValue) }
        )
    }

    private func workspacePullRequestCandidateSeed(
        workspace: Workspace,
        panelId: UUID,
        branch: String
    ) -> WorkspacePullRequestCandidateSeed {
        let directory = gitProbeDirectory(for: workspace, panelId: panelId)
        return WorkspacePullRequestCandidateSeed(
            workspaceId: workspace.id,
            panelId: panelId,
            branch: branch,
            directory: directory
        )
    }

    func scheduleWorkspacePullRequestRefresh(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarPullRequestPollingEnabled else {
            clearWorkspacePullRequestMetadata(for: key)
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
        cmuxDebugLog(
            "workspace.prRefresh.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif
        refreshTrackedWorkspacePullRequestsIfNeeded(reason: reason)
    }

    private func applyWorkspacePullRequestRefreshResults(
        _ results: [WorkspacePullRequestRefreshResult],
        repoResults: [String: WorkspacePullRequestRepoFetchResult],
        requestedKeys: [WorkspaceGitProbeKey],
        now: Date,
        reason: String
    ) {
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            workspacePullRequestRefreshTask = nil
            for key in requestedKeys {
                workspacePullRequestProbeStateByKey[key] = .idle
                workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.mobileHostBackgroundWorkQuietInterval)
            }
            deferWorkspacePullRequestRefreshForMobileHost()
            return
        }
        guard sidebarPullRequestPollingEnabled else {
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarPullRequestMetadata()
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
            if needsFollowUpPass {
                let shouldBypassRepoCache = workspacePullRequestFollowUpShouldBypassRepoCache
                workspacePullRequestFollowUpShouldBypassRepoCache = false
                refreshTrackedWorkspacePullRequestsIfNeeded(
                    reason: "\(reason).followUp",
                    allowCachedResultsOverride: shouldBypassRepoCache ? false : nil
                )
            }
        }

        for key in requestedKeys {
            let rerunPending = workspacePullRequestProbeRerunPending(for: key)
            workspacePullRequestProbeStateByKey[key] = .idle
            if rerunPending {
                workspacePullRequestNextPollAtByKey[key] = .distantPast
                needsFollowUpPass = true
            }

            guard requestedKeySet.contains(key),
                  let result = resultsByKey[key] else {
                continue
            }

            if rerunPending,
               workspacePullRequestFollowUpShouldBypassRepoCache,
               result.usedCachedRepoData {
                continue
            }

            guard let workspace = tabs.first(where: { $0.id == result.workspaceId }),
                  workspace.panels[result.panelId] != nil else {
                clearWorkspacePullRequestTracking(for: key)
                continue
            }

            let priorPullRequest = workspace.panelPullRequests[result.panelId]
            let countsAsTerminalSweep = priorPullRequest.map { $0.status != .open } ?? false

            switch result.resolution {
            case .resolved(let resolvedPullRequest):
                workspacePullRequestTransientFailureCountByKey[key] = 0
                guard let status = SidebarPullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
                      let url = URL(string: resolvedPullRequest.urlString) else {
                    continue
                }
                workspace.updatePanelPullRequest(
                    panelId: result.panelId,
                    number: resolvedPullRequest.number,
                    label: "PR",
                    url: url,
                    status: status,
                    branch: resolvedPullRequest.branch,
                    isStale: false
                )
            case .notFound:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if workspace.panelPullRequests[result.panelId] != nil {
                    workspace.clearPanelPullRequest(panelId: result.panelId)
                }
            case .unsupportedRepository:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if workspace.panelPullRequests[result.panelId] != nil {
                    workspace.clearPanelPullRequest(panelId: result.panelId)
                }
            case .transientFailure:
                let nextFailureCount = (workspacePullRequestTransientFailureCountByKey[key] ?? 0) + 1
                workspacePullRequestTransientFailureCountByKey[key] = nextFailureCount
                if nextFailureCount >= 3,
                   let currentPullRequest = workspace.panelPullRequests[result.panelId] {
                    workspace.updatePanelPullRequest(
                        panelId: result.panelId,
                        number: currentPullRequest.number,
                        label: currentPullRequest.label,
                        url: currentPullRequest.url,
                        status: currentPullRequest.status,
                        branch: currentPullRequest.branch,
                        isStale: true
                    )
                }
            }

            scheduleNextWorkspacePullRequestPoll(
                key: key,
                workspace: workspace,
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
            cmuxDebugLog(
                "workspace.prRefresh.apply workspace=\(result.workspaceId.uuidString.prefix(5)) " +
                "panel=\(result.panelId.uuidString.prefix(5)) result=\(label) reason=\(reason)"
            )
#endif
        }

        updateWorkspacePullRequestPollTimer()
    }

    private func scheduleNextWorkspacePullRequestPoll(
        key: WorkspaceGitProbeKey,
        workspace: Workspace,
        panelId: UUID,
        now: Date,
        resolution: WorkspacePullRequestRefreshResult.Resolution,
        countsAsTerminalSweep: Bool
    ) {
        if countsAsTerminalSweep {
            workspacePullRequestLastTerminalStateRefreshAtByKey[key] = now
        }

        if case .resolved(let resolvedPullRequest) = resolution,
           let status = SidebarPullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
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
        let baseInterval = isSelectedFocusedPanel(workspace: workspace, panelId: panelId)
            ? Self.selectedPollInterval
            : Self.backgroundPollInterval
        workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.jitteredPollInterval(base: baseInterval))
    }

    private func pruneWorkspacePullRequestTracking(validKeys: Set<WorkspaceGitProbeKey>) {
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

    func clearWorkspacePullRequestTracking(for key: WorkspaceGitProbeKey) {
        workspacePullRequestNextPollAtByKey.removeValue(forKey: key)
        workspacePullRequestProbeStateByKey.removeValue(forKey: key)
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
        workspacePullRequestTransientFailureCountByKey.removeValue(forKey: key)
        updateWorkspacePullRequestPollTimer()
    }

    func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        workspacePullRequestNextPollAtByKey = workspacePullRequestNextPollAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestProbeStateByKey = workspacePullRequestProbeStateByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestLastTerminalStateRefreshAtByKey = workspacePullRequestLastTerminalStateRefreshAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestTransientFailureCountByKey = workspacePullRequestTransientFailureCountByKey.filter { $0.key.workspaceId != workspaceId }
        updateWorkspacePullRequestPollTimer()
    }

    private func clearWorkspacePullRequestMetadata(for key: WorkspaceGitProbeKey) {
        clearWorkspacePullRequestTracking(for: key)
        guard let workspace = tabs.first(where: { $0.id == key.workspaceId }) else {
            return
        }
        workspace.clearPanelPullRequest(panelId: key.panelId)
    }

    func resetWorkspacePullRequestRefreshState() {
        workspacePullRequestRefreshTask?.cancel()
        workspacePullRequestRefreshTask = nil
        workspacePullRequestProbeStateByKey.removeAll()
        workspacePullRequestNextPollAtByKey.removeAll()
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeAll()
        workspacePullRequestTransientFailureCountByKey.removeAll()
        workspacePullRequestRepoCacheBySlug.removeAll()
        workspacePullRequestFollowUpShouldBypassRepoCache = false
        updateWorkspacePullRequestPollTimer()
    }

    private func markWorkspacePullRequestProbeRerunPending(
        for key: WorkspaceGitProbeKey,
        bypassRepoCache: Bool
    ) {
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key],
              !rerunPending else {
            if bypassRepoCache {
                workspacePullRequestFollowUpShouldBypassRepoCache = true
            }
            return
        }
        workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: true)
        if bypassRepoCache {
            workspacePullRequestFollowUpShouldBypassRepoCache = true
        }
    }

    private func workspacePullRequestProbeRerunPending(for key: WorkspaceGitProbeKey) -> Bool {
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key] else {
            return false
        }
        return rerunPending
    }

    func handleWorkspacePullRequestCommandHint(
        tabId: UUID,
        surfaceId: UUID,
        action: String,
        target: String?
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard sidebarPullRequestPollingEnabled else {
            clearWorkspacePullRequestMetadata(for: WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId))
            return
        }
        reconcileLocalPullRequestActionIfPossible(
            workspace: tab,
            panelId: surfaceId,
            action: action,
            target: target
        )
        scheduleWorkspacePullRequestRefresh(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "commandHint:\(action)"
        )
    }

    private func reconcileLocalPullRequestActionIfPossible(
        workspace: Workspace,
        panelId: UUID,
        action: String,
        target: String?
    ) {
        guard let currentPullRequest = workspace.panelPullRequests[panelId],
              pullRequestCommandTargetMatchesCurrentPullRequest(
                target,
                currentPullRequest: currentPullRequest
              ) else {
            return
        }

        let nextStatus: SidebarPullRequestStatus
        switch action {
        case "merge":
            guard currentPullRequest.status == .open else { return }
            nextStatus = .merged
        case "close":
            guard currentPullRequest.status == .open else { return }
            nextStatus = .closed
        case "reopen":
            guard currentPullRequest.status != .open else { return }
            nextStatus = .open
        default:
            return
        }

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: currentPullRequest.number,
            label: currentPullRequest.label,
            url: currentPullRequest.url,
            status: nextStatus,
            branch: currentPullRequest.branch,
            isStale: false
        )
    }

    private func pullRequestCommandTargetMatchesCurrentPullRequest(
        _ rawTarget: String?,
        currentPullRequest: SidebarPullRequestState
    ) -> Bool {
        let trimmedTarget = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTarget.isEmpty else { return true }

        let numberToken = trimmedTarget.hasPrefix("#") ? String(trimmedTarget.dropFirst()) : trimmedTarget
        if let number = Int(numberToken), number == currentPullRequest.number {
            return true
        }

        if let targetURL = URL(string: trimmedTarget) {
            if targetURL == currentPullRequest.url {
                return true
            }
            if let lastComponent = targetURL.pathComponents.last,
               let number = Int(lastComponent),
               number == currentPullRequest.number {
                return true
            }
        }

        if GitMetadataService.normalizedBranchName(trimmedTarget) == GitMetadataService.normalizedBranchName(currentPullRequest.branch) {
            return true
        }

        return false
    }

    func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

}
