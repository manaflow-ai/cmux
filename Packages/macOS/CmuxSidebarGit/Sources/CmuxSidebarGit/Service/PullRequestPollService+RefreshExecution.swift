import Foundation
import CmuxGit

// MARK: - Detached pull-request lookup execution and main-actor apply.

extension PullRequestPollService {
    struct PendingRefreshRequest {
        var reason: String
        var shouldBypassRepoCache: Bool
    }

    struct RefreshRequest {
        let seeds: [WorkspacePullRequestCandidateSeed]
        let keys: [WorkspaceGitProbeKey]
        let sources: [WorkspaceGitProbeKey: SourceIdentity]
        let cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry]
        let now: Date
        let allowCachedResults: Bool
        let bypassRepoCacheKeys: Set<WorkspaceGitProbeKey>
        let reason: String
    }

    func startWorkspacePullRequestRefresh(_ request: RefreshRequest) {
        workspacePullRequestRefreshGeneration &+= 1
        let authority = DetachedCompletionAuthority(
            generation: workspacePullRequestRefreshGeneration
        )
        workspacePullRequestRefreshAuthority = authority
        runtimeMetricsRecorder.recordPullRequestTaskStarted()

        let refreshExecutor = refreshExecutor
        let runtimeMetricsRecorder = runtimeMetricsRecorder
        workspacePullRequestRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let candidateResolution = await refreshExecutor.resolveCandidateSeeds(request.seeds)
            guard authority.isCurrent() else {
                runtimeMetricsRecorder.recordPullRequestStaleCompletionRejectedOffMain()
                await self?.discardRejectedWorkspacePullRequestRefresh(
                    authority: authority,
                    request: request
                )
                return
            }
            guard !Task.isCancelled else { return }

            if !candidateResolution.repoDirectoriesBySlug.isEmpty {
                runtimeMetricsRecorder.recordPullRequestRepoFetch()
            }
            let repoResults = await refreshExecutor.fetchRepoResults(
                candidateResolution: candidateResolution,
                cacheBySlug: request.cacheBySlug,
                now: request.now,
                allowCachedResults: request.allowCachedResults
            )
            let results = PullRequestProbeService.resolveRefreshResults(
                candidates: candidateResolution.candidates,
                repoResults: repoResults
            )
            guard authority.isCurrent() else {
                runtimeMetricsRecorder.recordPullRequestStaleCompletionRejectedOffMain()
                await self?.discardRejectedWorkspacePullRequestRefresh(
                    authority: authority,
                    request: request
                )
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard authority.isCurrent(),
                      self.workspacePullRequestRefreshAuthority === authority else {
                    self.discardRejectedWorkspacePullRequestRefresh(
                        authority: authority,
                        request: request
                    )
                    return
                }
                self.workspacePullRequestRefreshTask = nil
                self.workspacePullRequestRefreshAuthority = nil
                self.applyWorkspacePullRequestRefreshResults(
                    results,
                    repoResults: repoResults,
                    requestedKeys: request.keys,
                    requestedSourceByKey: request.sources,
                    now: Date(),
                    reason: request.reason
                )
            }
        }
    }

    /// Drains an invalidated completion without entering the apply path.
    /// Exactly one global follow-up owns every rerun and pending seed that
    /// accumulated while the rejected fetch was in flight.
    func discardRejectedWorkspacePullRequestRefresh(
        authority: DetachedCompletionAuthority,
        request: RefreshRequest
    ) {
        guard workspacePullRequestRefreshAuthority === authority else { return }
        workspacePullRequestRefreshTask = nil
        workspacePullRequestRefreshAuthority = nil

        var survivingKeys: Set<WorkspaceGitProbeKey> = []
        for key in request.keys {
            guard workspacePullRequestSourceByKey[key] != nil,
                  host?.panelExists(workspaceId: key.workspaceId, panelId: key.panelId) == true else {
                continue
            }
            survivingKeys.insert(key)
            workspacePullRequestProbeStateByKey[key] = .idle
            workspacePullRequestNextPollAtByKey[key] = .distantPast
        }
        let survivingBypassRepoCacheKeys = request.bypassRepoCacheKeys.intersection(survivingKeys)
        workspacePullRequestBypassRepoCacheKeys.formUnion(survivingBypassRepoCacheKeys)

        let pendingSeedRefresh = takePendingSeedRefresh()
        let pendingRefreshRequest = takePendingRefreshRequest()
        guard !survivingKeys.isEmpty || pendingSeedRefresh != nil || pendingRefreshRequest != nil else {
            updateWorkspacePullRequestPollTimer()
            return
        }

        let shouldBypassRepoCache =
            !survivingBypassRepoCacheKeys.isEmpty
            || pendingSeedRefresh?.shouldBypassRepoCache == true
            || pendingRefreshRequest?.shouldBypassRepoCache == true
        startWorkspacePullRequestFollowUp(
            reason: "\(pendingRefreshRequest?.reason ?? request.reason).followUp",
            shouldBypassRepoCache: shouldBypassRepoCache
        )
    }

    func queueWorkspacePullRequestRefreshFollowUp(
        reason: String,
        shouldBypassRepoCache: Bool
    ) {
        if var pending = workspacePullRequestPendingRefreshRequest {
            pending.reason = reason
            pending.shouldBypassRepoCache =
                pending.shouldBypassRepoCache || shouldBypassRepoCache
            workspacePullRequestPendingRefreshRequest = pending
        } else {
            workspacePullRequestPendingRefreshRequest = PendingRefreshRequest(
                reason: reason,
                shouldBypassRepoCache: shouldBypassRepoCache
            )
        }
    }

    @discardableResult
    func takePendingRefreshRequest() -> PendingRefreshRequest? {
        defer { workspacePullRequestPendingRefreshRequest = nil }
        return workspacePullRequestPendingRefreshRequest
    }
}
