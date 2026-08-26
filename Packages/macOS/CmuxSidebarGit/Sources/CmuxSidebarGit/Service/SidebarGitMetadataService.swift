public import Foundation
public import CmuxGit
internal import CmuxFoundation
internal import os

/// The production ``SidebarGitMetadataServing``: owns the local git probe
/// state machine (per-panel probe/rerun flags, retry tasks, tracked
/// directories, clean-index/head signatures, per-directory snapshot dedupe),
/// and the filesystem watchers on each repository's Git-relevant paths.
///
/// **Isolation.** `@MainActor`, not an actor: every mutator of this state
/// machine lives on the main actor (host entry points, the retry
/// tasks, watcher event consumers, the snapshot apply hop), and each
/// transition synchronously interleaves host reads (does the panel still
/// exist, is its directory still the probed one) with host writes (branch
/// projection) and follow-up scheduling. Co-locating the state with its
/// callers keeps those turns atomic; the only off-main work is the metadata
/// read itself, which runs on a detached utility task gated by the injected
/// process-wide ``WorkspaceGitMetadataProbeLimiter`` exactly as in the
/// legacy code.
///
/// The initial probe retry offsets remain `[0, 0.5, 1.5, 3, 6, 10]` seconds.
/// After that bootstrap, refreshes are event-driven; there is no timer that
/// periodically re-stats every tracked repository.
@MainActor
public final class SidebarGitMetadataService: SidebarGitMetadataServing {
    nonisolated static let gitWatchDiagnosticsLogger = Logger(
        subsystem: "com.cmuxterm",
        category: "sidebar-git"
    )
    // MARK: Tuning constants (legacy TabManager values, preserved exactly)

    nonisolated static let initialWorkspaceGitProbeDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0, 6.0, 10.0]

    // MARK: Dependencies

    // Reads on-disk git metadata (branch, dirty state, signatures) off the
    // main actor. Stateless; injected so tests supply a fake reader.
    let workspaceGitMetadataReader: any WorkspaceGitMetadataReading
    // Resolves the Git-aware event plan for a directory.
    let gitMetadataService: any GitMetadataWatchDescriptorReading
    // PR polling: a local probe that finds a branch schedules a refresh here,
    // and probe teardown clears the matching PR tracking.
    let pullRequestProbing: any PullRequestProbing
    // Process-wide cap on concurrent snapshot probes (injected, shared
    // across windows by the composition root).
    let probeLimiter: WorkspaceGitMetadataProbeLimiter
    // Drives the initial-probe retry gaps.
    let clock: any GitPollClock
    // Mobile-host background-work deferral intervals.
    let mobileHostDeferral: MobileHostDeferralPolicy
    // Debug diagnostics sink (the app injects its debug logger in DEBUG).
    let debugLog: @Sendable (String) -> Void
    // The window-side seam; set once via attach(host:). Weak: the host owns
    // this service.
    private(set) weak var host: (any SidebarGitHosting)?

    // MARK: Probe state (all main-actor; see isolation note above)

    var workspaceGitProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    var workspaceGitProbeTasksByKey: [WorkspaceGitProbeKey: Task<Void, Never>] = [:]
    var workspaceGitTrackedDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitCleanIndexSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitCleanIndexContentSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitHeadSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitMetadataWatcherSourceDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    var workspaceGitMetadataWatcherKeysBySourceDirectory: [String: Set<WorkspaceGitProbeKey>] = [:]
    var workspaceGitMetadataWatchersByWatchedPathsKey: [WorkspaceGitMetadataWatchedPathsKey: RecursivePathWatcher] = [:]
    var workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey: [WorkspaceGitMetadataWatchedPathsKey: Task<Void, Never>] = [:]
    var workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey: [WorkspaceGitProbeKey: WorkspaceGitMetadataWatchedPathsKey] = [:]
    var workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey: [WorkspaceGitMetadataWatchedPathsKey: Set<WorkspaceGitProbeKey>] = [:]
    var workspaceGitMetadataWatcherDescriptorRequestsByKey: [WorkspaceGitProbeKey: WorkspaceGitMetadataWatcherDescriptorRequest] = [:]
    var workspaceGitMetadataWatcherDescriptorInvalidatedKeys: Set<WorkspaceGitProbeKey> = []
    var workspaceGitMetadataDegradationLoggedRepositoryRoots: Set<String> = []
    var workspaceGitMetadataWatcherDescriptorGeneration: UInt64 = 0
    var workspaceGitMetadataFilesystemEventGeneration: UInt64 = 0
    let workspaceGitSnapshotCacheNamespace = UUID()
    var workspaceGitSnapshotCacheGenerationByDirectory: [String: UInt64] = [:]
    var workspaceGitSnapshotRequestsByDirectory: [String: [WorkspaceGitProbeKey: WorkspaceGitSnapshotProbeRequest]] = [:]
    var workspaceGitSnapshotTasksByDirectory: [String: Task<Void, Never>] = [:]
    var workspaceGitSnapshotTaskContextByDirectory: [String: WorkspaceGitSnapshotTaskContext] = [:]
    var workspaceGitSnapshotDirectoryByProbeKey: [WorkspaceGitProbeKey: String] = [:]
    private var lastSidebarGitMetadataActivity: SidebarGitMetadataActivity = .disabled

    /// Creates the metadata service.
    ///
    /// - Parameters:
    ///   - workspaceGitMetadataReader: Reads a directory's git metadata;
    ///     tests pass a fake.
    ///   - gitMetadataService: Resolves watched git paths for the watcher.
    ///   - pullRequestProbing: The PR poll service driven by probe outcomes.
    ///   - probeLimiter: Process-wide concurrent probe cap.
    ///   - clock: Initial-probe retry clock; tests inject virtual time.
    ///   - mobileHostDeferral: Mobile-host deferral intervals.
    ///   - debugLog: Diagnostics sink; defaults to a no-op.
    public init(
        workspaceGitMetadataReader: any WorkspaceGitMetadataReading,
        gitMetadataService: any GitMetadataWatchDescriptorReading,
        pullRequestProbing: any PullRequestProbing,
        probeLimiter: WorkspaceGitMetadataProbeLimiter,
        clock: any GitPollClock = SystemGitPollClock(),
        mobileHostDeferral: MobileHostDeferralPolicy = .standard,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.workspaceGitMetadataReader = workspaceGitMetadataReader
        self.gitMetadataService = gitMetadataService
        self.pullRequestProbing = pullRequestProbing
        self.probeLimiter = probeLimiter
        self.clock = clock
        self.mobileHostDeferral = mobileHostDeferral
        self.debugLog = debugLog
    }

    deinit {
        for task in workspaceGitProbeTasksByKey.values {
            task.cancel()
        }
        for task in workspaceGitSnapshotTasksByDirectory.values {
            task.cancel()
        }
    }

    /// Wires the host and captures the initial watch-setting value (matching
    /// the legacy property-initializer capture timing: before any scheduling
    /// entry point runs).
    public func attach(host: any SidebarGitHosting) {
        self.host = host
        lastSidebarGitMetadataActivity = host.gitMetadataActivity
    }

    var sidebarGitMetadataActivePollingEnabled: Bool {
        host?.gitMetadataActivity.performsActivePolling ?? false
    }

    var sidebarPullRequestPollingEnabled: Bool {
        host?.pullRequestActivity.performsActivePolling ?? false
    }

    // MARK: Explicit refresh

    /// Explicit/manual refresh entry point retained for diagnostics and tests.
    /// Production freshness after the initial probe is driven by FSEvents.
    public func refreshTrackedWorkspaceGitMetadata(reason: String) {
        guard let host else { return }
        let activeProbeKeys = activeWorkspaceGitProbeKeys

        for workspaceId in host.orderedWorkspaceIds() {
            for panelId in trackedWorkspaceGitMetadataPollCandidatePanelIds(
                workspaceId: workspaceId,
                activeProbeKeys: activeProbeKeys
            ) {
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
    }

    // MARK: Settings

    public func sidebarGitMetadataWatchSettingsDidChange() {
        let activity = host?.gitMetadataActivity ?? .disabled
        guard activity != lastSidebarGitMetadataActivity else {
            return
        }
        lastSidebarGitMetadataActivity = activity

        guard activity.performsActivePolling else {
            resetAllWorkspaceGitProbeTracking()
            if activity == .disabled {
                host?.clearAllSidebarGitMetadata()
            }
            return
        }

        restartWorkspaceGitMetadataWatching(reason: "gitWatchSettingEnabled")
    }

    private func restartWorkspaceGitMetadataWatching(reason: String) {
        guard let host else { return }
        for workspaceId in host.orderedWorkspaceIds() {
            for panelId in host.panelIds(in: workspaceId) {
                guard !host.shouldSkipLocalGitMetadata(workspaceId: workspaceId, panelId: panelId) else { continue }
                guard host.hasTerminalPanel(workspaceId: workspaceId, panelId: panelId) else {
                    continue
                }
                if let directory = host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId) {
                    let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
                    workspaceGitTrackedDirectoryByKey[key] = directory
                    updateWorkspaceGitMetadataWatcher(for: key, directory: directory)
                }
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
    }

    // MARK: Poll candidates

    var activeWorkspaceGitProbeKeys: Set<WorkspaceGitProbeKey> {
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

    private func trackedWorkspaceGitMetadataPollCandidatePanelIds(
        workspaceId: UUID,
        activeProbeKeys: Set<WorkspaceGitProbeKey>
    ) -> Set<UUID> {
        guard let host else { return [] }
        var candidatePanelIds = host.panelGitBranchPanelIds(in: workspaceId)
        candidatePanelIds.formUnion(host.panelPullRequestPanelIds(in: workspaceId))
        // Only keep background polling panels whose current directory has already
        // proven to yield sidebar git metadata. Initial multi-attempt probes handle
        // startup races; this avoids polling non-repo directories forever.
        candidatePanelIds.formUnion(
            host.panelIds(in: workspaceId).compactMap { panelId in
                guard let currentDirectory = host.gitProbeDirectory(workspaceId: workspaceId, panelId: panelId) else {
                    return nil
                }
                let probeKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
                guard workspaceGitTrackedDirectoryByKey[probeKey] == currentDirectory else {
                    return nil
                }
                return panelId
            }
        )

        if candidatePanelIds.isEmpty,
           let focusedPanelId = host.focusedPanelId(in: workspaceId),
           host.hasWorkspaceLevelGitSignal(workspaceId),
           host.gitProbeDirectory(workspaceId: workspaceId, panelId: focusedPanelId) != nil {
            candidatePanelIds.insert(focusedPanelId)
        }

        return Set(candidatePanelIds.filter { panelId in
            let probeKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
            return !host.shouldSkipLocalGitMetadata(workspaceId: workspaceId, panelId: panelId) &&
                !activeProbeKeys.contains(probeKey)
        })
    }

    // MARK: Teardown

    func clearWorkspaceGitProbe(_ key: WorkspaceGitProbeKey) {
        removeWorkspaceGitSnapshotRequest(for: key)
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        workspaceGitCleanIndexSignatureByKey.removeValue(forKey: key)
        workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: key)
        workspaceGitHeadSignatureByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTask(for: key)
        stopWorkspaceGitMetadataWatcher(for: key)
    }

    func finishWorkspaceGitProbeAttempt(_ key: WorkspaceGitProbeKey) {
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTask(for: key)
    }

    func clearWorkspaceGitMetadata(for key: WorkspaceGitProbeKey) {
        clearWorkspaceGitProbeTracking(for: key)
        guard let host, host.workspaceExists(key.workspaceId) else {
            return
        }
        host.clearPanelGitBranch(workspaceId: key.workspaceId, panelId: key.panelId)
        host.clearPanelPullRequest(workspaceId: key.workspaceId, panelId: key.panelId)
    }

    func clearWorkspaceGitProbeTracking(for key: WorkspaceGitProbeKey) {
        clearWorkspaceGitProbe(key)
        workspaceGitTrackedDirectoryByKey.removeValue(forKey: key)
        pullRequestProbing.clearWorkspacePullRequestTracking(
            workspaceId: key.workspaceId,
            panelId: key.panelId
        )
    }

    public func clearWorkspaceGitProbes(workspaceId: UUID) {
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
        pullRequestProbing.clearWorkspacePullRequestTracking(workspaceId: workspaceId)
    }

    public func resetAllWorkspaceGitProbeTracking() {
        stopAllWorkspaceGitMetadataWatchers()
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
        pullRequestProbing.resetWorkspacePullRequestRefreshState()
    }

    // MARK: Test seams

    public func trackedWorkspaceGitMetadataPollCandidatePanelIds(workspaceId: UUID) -> Set<UUID> {
        let activeProbeKeys = activeWorkspaceGitProbeKeys
        guard let host, host.workspaceExists(workspaceId) else {
            return []
        }
        return trackedWorkspaceGitMetadataPollCandidatePanelIds(
            workspaceId: workspaceId,
            activeProbeKeys: activeProbeKeys
        )
    }

    public func activeWorkspaceGitProbePanelIds(workspaceId: UUID) -> Set<UUID> {
        let probeKeys = Set(workspaceGitProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTasksByKey.keys.filter { $0.workspaceId == workspaceId })
        return Set(probeKeys.map(\.panelId))
    }
}
