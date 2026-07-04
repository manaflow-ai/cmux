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

    // Resolves slugs for candidate seeds (stateless CmuxGit reader).
    let gitMetadataService: GitMetadataService
    // Fetches and matches GitHub PRs (stateless CmuxGit pipeline).
    let probeService: PullRequestProbeService
    // Drives the poll deadline and mobile-host deferral sleeps.
    let clock: any GitPollClock
    // Mobile-host background-work deferral intervals.
    let mobileHostDeferral: MobileHostDeferralPolicy
    // Debug diagnostics sink (the app injects its debug logger in DEBUG).
    let debugLog: @Sendable (String) -> Void
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
    var workspacePullRequestFollowUpShouldBypassRepoCache = false
    var lastSidebarPullRequestPollingEnabled = false
    var lastSidebarPullRequestCIStatusEnabled = false

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
        self.gitMetadataService = gitMetadataService
        self.probeService = probeService
        self.clock = clock
        self.mobileHostDeferral = mobileHostDeferral
        self.debugLog = debugLog
    }

    deinit {
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestRefreshTask?.cancel()
    }

    /// Wires the host and captures the initial polling-setting value
    /// (matching the legacy property-initializer capture timing: before any
    /// scheduling entry point runs).
    public func attach(host: any SidebarGitHosting) {
        self.host = host
        lastSidebarPullRequestPollingEnabled = host.isPullRequestPollingEnabled
        lastSidebarPullRequestCIStatusEnabled = host.isPullRequestCIStatusEnabled
        updateWorkspacePullRequestPollTimer()
    }

    var sidebarPullRequestPollingEnabled: Bool {
        host?.isPullRequestPollingEnabled ?? false
    }

    var sidebarPullRequestCIStatusEnabled: Bool {
        host?.isPullRequestCIStatusEnabled ?? false
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
        refreshTrackedWorkspacePullRequestsIfNeeded(reason: reason, allowCachedResultsOverride: nil)
    }

    func refreshTrackedWorkspacePullRequestsIfNeeded(
        reason: String,
        allowCachedResultsOverride: Bool?
    ) {
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

        let now = Date()
        var candidateSeeds: [WorkspacePullRequestCandidateSeed] = []
        var requestedKeys: [WorkspaceGitProbeKey] = []
        var validKeys: Set<WorkspaceGitProbeKey> = []

        for workspaceId in host.orderedWorkspaceIds() {
            let branchPanelIds = host.panelGitBranchPanelIds(in: workspaceId)
            let badgePanelIds = host.panelPullRequestPanelIds(in: workspaceId)
            for panelId in branchPanelIds.union(badgePanelIds) {
                let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
                validKeys.insert(key)
                let branch = GitMetadataService.normalizedBranchName(
                    host.panelGitBranch(workspaceId: workspaceId, panelId: panelId)?.branch
                        ?? host.panelPullRequestBadge(workspaceId: workspaceId, panelId: panelId)?.branch
                )
                guard let branch else {
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                if PullRequestProbeService.shouldSkipLookup(branch: branch) {
                    host.clearPanelPullRequest(workspaceId: workspaceId, panelId: panelId)
                    clearWorkspacePullRequestTracking(for: key)
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
                    markWorkspacePullRequestProbeRerunPending(
                        for: key,
                        bypassRepoCache: !PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
                    )
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
        let probeService = probeService
        let seeds = candidateSeeds
        let keys = requestedKeys
        let includeCIStatus = sidebarPullRequestCIStatusEnabled
        workspacePullRequestRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let candidateResolution = await probeService.resolveCandidateSeeds(
                seeds,
                gitMetadata: gitMetadataService
            )
            guard !Task.isCancelled else { return }
            let repoResults = await probeService.fetchRepoResults(
                repoDirectoriesBySlug: candidateResolution.repoDirectoriesBySlug,
                candidateBranchesByRepo: candidateResolution.candidateBranchesByRepo,
                cacheBySlug: cacheBySlug,
                now: now,
                allowCachedResults: allowCachedResults,
                includeCIStatus: includeCIStatus
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
                    requestedKeys: keys,
                    now: Date(),
                    reason: reason
                )
            }
        }
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
