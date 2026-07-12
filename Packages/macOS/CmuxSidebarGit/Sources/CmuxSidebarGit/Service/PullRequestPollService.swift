public import Foundation
public import CmuxGit

/// The production ``PullRequestProbing``: owns the pull-request poll state
/// machine (per-panel deadlines, in-flight/rerun flags, transient-failure
/// counts, the short-lived repo cache) and drives refreshes through the
/// stateless `CmuxGit` ``CmuxGit/PullRequestProbeService`` pipeline.
///
/// **Isolation.** `@MainActor`, not an actor: every mutator of this state
/// machine lives on the main actor (host entry points, the poll-deadline
/// task, the apply hop at the end of a refresh), and each transition
/// synchronously interleaves host reads (current badge, panel existence)
/// with host writes (badge projection). Co-locating the state with its
/// callers keeps those turns atomic; a private actor would only manufacture
/// bridges. The blocking work (slug resolution, GitHub REST fetch) never
/// runs here — it stays on a detached utility task exactly as in the legacy
/// code, with only the apply hopping back.
///
/// The deliberate poll cadence is sanctioned and preserved exactly:
/// 10s selected / 60s background with ±10% jitter, 15-minute terminal-state
/// sweeps, max-3-panel refresh batches, 60s repo-cache prune lifetime, and
/// the `max(0.25, …)` poll-deadline floor.
@MainActor
public final class PullRequestPollService: PullRequestProbing {
    // MARK: Tuning constants (legacy TabManager values, preserved exactly)

    nonisolated static let backgroundPollInterval: TimeInterval = 60
    nonisolated static let selectedPollInterval: TimeInterval = 10
    nonisolated static let workspacePullRequestRepoCachePruneLifetime: TimeInterval = 60
    nonisolated static let workspacePullRequestPollJitterFraction = 0.10
    nonisolated static let workspacePullRequestRefreshBatchLimit = 3

    // MARK: Dependencies

    // Runs slug resolution and GitHub fetches off-main. The production
    // executor wraps the stateless CmuxGit services; tests inject a gated
    // executor at this exact remote-fetch boundary.
    let refreshExecutor: any PullRequestRefreshExecuting
    // Drives the poll deadline and mobile-host deferral sleeps.
    let clock: any GitPollClock
    // Mobile-host background-work deferral intervals.
    let mobileHostDeferral: MobileHostDeferralPolicy
    // Debug diagnostics sink (the app injects its debug logger in DEBUG).
    let debugLog: @Sendable (String) -> Void
    // Defaults to the process-wide opt-in recorder. Focused tests replace it
    // with an isolated enabled instance so causal counts stay deterministic.
    var runtimeMetricsRecorder = SidebarGitMetadataService.runtimeMetrics
    // The window-side seam; set once via attach(host:). Weak: the host owns
    // this service.
    weak var host: (any SidebarGitHosting)?

    // MARK: Poll state (all main-actor; see isolation note above)

    var workspacePullRequestProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    var workspacePullRequestNextPollAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    var workspacePullRequestLastTerminalStateRefreshAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    var workspacePullRequestTransientFailureCountByKey: [WorkspaceGitProbeKey: Int] = [:]
    var workspacePullRequestRepoCacheBySlug: [String: WorkspacePullRequestRepoCacheEntry] = [:]
    var workspacePullRequestPollTask: Task<Void, Never>?
    var workspacePullRequestRefreshTask: Task<Void, Never>?
    var workspacePullRequestRefreshAuthority: DetachedCompletionAuthority?
    var workspacePullRequestRefreshGeneration: UInt64 = 0
    var workspacePullRequestFollowUpShouldBypassRepoCache = false
    var workspacePullRequestSourceByKey: [WorkspaceGitProbeKey: SourceIdentity] = [:]
    var workspacePullRequestSeedRefreshTask: Task<Void, Never>?
    var workspacePullRequestPendingSeedRefresh: PendingSeedRefresh?
    var lastSidebarPullRequestPollingEnabled = false

    /// Creates the poll service.
    ///
    /// - Parameters:
    ///   - gitMetadataService: Resolves GitHub slugs for candidate seeds.
    ///   - probeService: The stateless fetch/match pipeline.
    ///   - clock: Poll-deadline clock; tests inject virtual time.
    ///   - mobileHostDeferral: Mobile-host deferral intervals.
    ///   - debugLog: Diagnostics sink; defaults to a no-op.
    public init(
        gitMetadataService: GitMetadataService,
        probeService: PullRequestProbeService,
        clock: any GitPollClock = SystemGitPollClock(),
        mobileHostDeferral: MobileHostDeferralPolicy = .standard,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.refreshExecutor = LivePullRequestRefreshExecutor(
            gitMetadataService: gitMetadataService,
            probeService: probeService
        )
        self.clock = clock
        self.mobileHostDeferral = mobileHostDeferral
        self.debugLog = debugLog
    }

    init(
        refreshExecutor: any PullRequestRefreshExecuting,
        clock: any GitPollClock = SystemGitPollClock(),
        mobileHostDeferral: MobileHostDeferralPolicy = .standard,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.refreshExecutor = refreshExecutor
        self.clock = clock
        self.mobileHostDeferral = mobileHostDeferral
        self.debugLog = debugLog
    }

    deinit {
        workspacePullRequestRefreshAuthority?.invalidate()
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestRefreshTask?.cancel()
        workspacePullRequestSeedRefreshTask?.cancel()
    }

    /// Wires the host and captures the initial polling-setting value
    /// (matching the legacy property-initializer capture timing: before any
    /// scheduling entry point runs).
    public func attach(host: any SidebarGitHosting) {
        self.host = host
        lastSidebarPullRequestPollingEnabled = host.isPullRequestPollingEnabled
        updateWorkspacePullRequestPollTimer()
    }

    var sidebarPullRequestPollingEnabled: Bool {
        host?.isPullRequestPollingEnabled ?? false
    }

    // MARK: Poll timer

    func updateWorkspacePullRequestPollTimer() {
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil

        guard sidebarPullRequestPollingEnabled,
              workspacePullRequestRefreshTask == nil,
              let nextPollAt = workspacePullRequestNextPollAtByKey.values.min() else {
            return
        }

        let delay = max(0.25, nextPollAt.timeIntervalSinceNow)
        let clock = clock
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
    func deferWorkspacePullRequestRefreshForMobileHost() {
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil

        let quietDelay = host?.mobileHostQuietDelay(for: mobileHostDeferral.quietInterval) ?? 0
        let delay = max(mobileHostDeferral.deferralInterval, quietDelay)
        let clock = clock
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

    // MARK: Refresh pass

    public func refreshTrackedWorkspacePullRequestsIfNeeded(reason: String) {
        // Equivalent periodic requests join the active fetch in O(1). A
        // source seed or cache-bypassing request must still traverse so it can
        // invalidate stale authority and own the single follow-up.
        if workspacePullRequestRefreshTask != nil,
           sidebarPullRequestPollingEnabled,
           host?.mobileHostHasRecentActivity(within: mobileHostDeferral.quietInterval) != true,
           workspacePullRequestPendingSeedRefresh == nil,
           PullRequestProbeService.refreshAllowsRepoCache(reason: reason) {
            runtimeMetricsRecorder.recordPullRequestRefreshRequest()
            runtimeMetricsRecorder.recordPullRequestTaskJoined()
            return
        }
        // If another refresh is already running, its apply owns the pending
        // seed and the one follow-up pass. Consuming it here would lose a seed
        // for a panel outside the current request batch when this traversal
        // reaches the in-flight-task guard below.
        let pendingSeedRefresh = workspacePullRequestRefreshTask == nil
            ? takePendingSeedRefresh()
            : workspacePullRequestPendingSeedRefresh
        refreshTrackedWorkspacePullRequestsIfNeeded(
            reason: reason,
            allowCachedResultsOverride: pendingSeedRefresh?.shouldBypassRepoCache == true ? false : nil
        )
    }

    func refreshTrackedWorkspacePullRequestsIfNeeded(
        reason: String,
        allowCachedResultsOverride: Bool?
    ) {
        runtimeMetricsRecorder.recordPullRequestRefreshRequest()
        guard let host else { return }
        guard !host.mobileHostHasRecentActivity(within: mobileHostDeferral.quietInterval) else {
            deferWorkspacePullRequestRefreshForMobileHost()
            return
        }
        guard sidebarPullRequestPollingEnabled else {
            resetWorkspacePullRequestRefreshState()
            host.clearAllSidebarPullRequestMetadata()
            return
        }
        SidebarGitMetadataService.recordPullRequestTraversal()

        let now = Date()
        var candidateSeeds: [WorkspacePullRequestCandidateSeed] = []
        var requestedKeys: [WorkspaceGitProbeKey] = []
        var requestedSourceByKey: [WorkspaceGitProbeKey: SourceIdentity] = [:]
        var validKeys: Set<WorkspaceGitProbeKey> = []

        for workspaceId in host.orderedWorkspaceIds() {
            let branchPanelIds = host.panelGitBranchPanelIds(in: workspaceId)
            let badgePanelIds = host.panelPullRequestPanelIds(in: workspaceId)
            for panelId in branchPanelIds.union(badgePanelIds) {
                guard !host.shouldSkipLocalGitMetadata(workspaceId: workspaceId, panelId: panelId) else { continue }
                let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
                validKeys.insert(key)
                let branch = GitMetadataService.normalizedBranchName(
                    host.panelGitBranch(workspaceId: workspaceId, panelId: panelId)?.branch
                        ?? host.panelPullRequestBadge(workspaceId: workspaceId, panelId: panelId)?.branch
                )
                guard let branch else {
                    workspacePullRequestSourceByKey.removeValue(forKey: key)
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                let source = SourceIdentity(
                    directory: host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId)?
                        .normalizedGitProbeDirectory ?? "",
                    branch: branch
                )
                let previousSource = workspacePullRequestSourceByKey[key]
                workspacePullRequestSourceByKey[key] = source

                if PullRequestProbeService.shouldSkipLookup(branch: branch) {
                    if host.panelPullRequestBadge(workspaceId: workspaceId, panelId: panelId) != nil {
                        host.clearPanelPullRequest(workspaceId: workspaceId, panelId: panelId)
                    }
                    clearWorkspacePullRequestTracking(for: key, preservingSource: true)
                    continue
                }

                if case .inFlight = workspacePullRequestProbeStateByKey[key],
                   previousSource != source {
                    markWorkspacePullRequestProbeRerunPending(
                        for: key,
                        bypassRepoCache: !PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
                    )
                    continue
                }

                guard shouldRefreshWorkspacePullRequest(
                    key: key,
                    now: now,
                    currentPullRequest: host.panelPullRequestBadge(workspaceId: workspaceId, panelId: panelId)
                ) else {
                    continue
                }

                if case .inFlight = workspacePullRequestProbeStateByKey[key] {
                    let bypassesRepoCache = !PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
                    if bypassesRepoCache {
                        markWorkspacePullRequestProbeRerunPending(
                            for: key,
                            bypassRepoCache: bypassesRepoCache
                        )
                    }
                    continue
                }

                let candidateSeed = WorkspacePullRequestCandidateSeed(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    branch: branch,
                    directory: host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId)
                )
                candidateSeeds.append(candidateSeed)
                requestedKeys.append(key)
                requestedSourceByKey[key] = source
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

        startWorkspacePullRequestRefresh(
            RefreshRequest(
                seeds: candidateSeeds,
                keys: requestedKeys,
                sources: requestedSourceByKey,
                cacheBySlug: workspacePullRequestRepoCacheBySlug,
                now: now,
                allowCachedResults: allowCachedResultsOverride
                    ?? PullRequestProbeService.refreshAllowsRepoCache(reason: reason),
                reason: reason
            )
        )
    }

    func shouldRefreshWorkspacePullRequest(
        key: WorkspaceGitProbeKey,
        now: Date,
        currentPullRequest: SidebarPullRequestBadge?
    ) -> Bool {
        PullRequestProbeService.shouldRefresh(
            now: now,
            nextPollAt: workspacePullRequestNextPollAtByKey[key],
            lastTerminalStateRefreshAt: workspacePullRequestLastTerminalStateRefreshAtByKey[key],
            currentStatus: currentPullRequest?.status
        )
    }

    public func scheduleWorkspacePullRequestRefresh(
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
        debugLog(
            "workspace.prRefresh.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif
        refreshTrackedWorkspacePullRequestsIfNeeded(reason: reason)
    }
}
