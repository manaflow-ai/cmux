public import Foundation

/// Drives GHPR metadata independently from the normal Git/PR polling cadence.
///
/// One 60-second timer refreshes all currently displayed pull requests. PR list
/// changes are coalesced per workspace for 1.5 seconds, while a manual refresh
/// runs immediately. Successful snapshots replace badges; transport and schema
/// failures preserve the last valid metadata and update ``GHPRRefreshState``.
@MainActor
public final class GHPRMetadataService {
    public nonisolated static let refreshInterval: Duration = .seconds(60)
    public nonisolated static let refreshDebounceInterval: Duration = .milliseconds(1_500)

    private let fetcher: any GHPRPullRequestFetching
    private let clock: any GitPollClock
    private let debugLog: @Sendable (String) -> Void
    private weak var host: (any GHPRMetadataHosting)?
    private var periodicTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRefreshAll = false
    private var pendingWorkspaceIds = Set<UUID>()
    private var lastConfiguration: GHPRConfiguration?
    private var refreshGeneration: UInt64 = 0

    public init(
        fetcher: any GHPRPullRequestFetching = GHPRSocketClient(),
        clock: any GitPollClock = SystemGitPollClock(),
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fetcher = fetcher
        self.clock = clock
        self.debugLog = debugLog
    }

    deinit {
        periodicTask?.cancel()
        refreshTask?.cancel()
        for task in debounceTasks.values { task.cancel() }
    }

    public func attach(host: any GHPRMetadataHosting) {
        self.host = host
        lastConfiguration = host.ghprConfiguration
        applyConfiguration(host.ghprConfiguration, refreshWhenEnabled: false)
    }

    /// Reacts to the `digest.ghpr.*` settings changing.
    public func settingsDidChange() {
        guard let host else { return }
        let configuration = host.ghprConfiguration
        guard configuration != lastConfiguration else { return }
        lastConfiguration = configuration
        cancelActiveRefresh()
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        pendingRefreshAll = false
        pendingWorkspaceIds.removeAll()
        applyConfiguration(configuration, refreshWhenEnabled: true)
    }

    /// Coalesces PR-list changes without coupling GHPR requests to each Git poll.
    public func requestRefresh(workspaceId: UUID) {
        guard let host, host.ghprConfiguration.enabled else {
            host?.clearGHPRBadges(workspaceId: workspaceId)
#if DEBUG
            debugLog("ghpr.refresh.request skip=disabled workspace=\(workspaceId.uuidString.prefix(5))")
#endif
            return
        }
        guard debounceTasks[workspaceId] == nil else {
#if DEBUG
            debugLog("ghpr.refresh.request coalesced=1 workspace=\(workspaceId.uuidString.prefix(5))")
#endif
            return
        }
#if DEBUG
        debugLog("ghpr.refresh.request scope=workspace workspace=\(workspaceId.uuidString.prefix(5))")
#endif
        let clock = clock
        debounceTasks[workspaceId] = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: Self.refreshDebounceInterval)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.debounceTasks[workspaceId] = nil
            self.startRefresh(workspaceIds: [workspaceId])
        }
    }

    /// Immediately refreshes all displayed pull requests from PRDashboard.
    public func refreshAll() {
#if DEBUG
        debugLog("ghpr.refresh.request scope=all")
#endif
        startRefresh(workspaceIds: nil)
    }

    private func applyConfiguration(_ configuration: GHPRConfiguration, refreshWhenEnabled: Bool) {
        periodicTask?.cancel()
        periodicTask = nil
        guard configuration.enabled else {
            cancelActiveRefresh()
            for task in debounceTasks.values { task.cancel() }
            debounceTasks.removeAll()
            pendingRefreshAll = false
            pendingWorkspaceIds.removeAll()
            host?.clearAllGHPRBadges()
            host?.ghprRefreshStateDidChange(GHPRRefreshState())
            return
        }
        startPeriodicRefreshTask()
        if refreshWhenEnabled { startRefresh(workspaceIds: nil) }
    }

    private func cancelActiveRefresh() {
        let hadActiveRefresh = refreshTask != nil
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        host?.ghprRefreshStateDidChange(GHPRRefreshState())
#if DEBUG
        if hadActiveRefresh {
            debugLog("ghpr.refresh.cancel")
        }
#endif
    }

    private func startPeriodicRefreshTask() {
        let clock = clock
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.startRefresh(workspaceIds: nil)
            }
        }
    }

    private func startRefresh(workspaceIds: Set<UUID>?) {
        guard let host else { return }
        let configuration = host.ghprConfiguration
        guard configuration.enabled else {
#if DEBUG
            debugLog("ghpr.refresh.skip reason=disabled")
#endif
            applyConfiguration(configuration, refreshWhenEnabled: false)
            return
        }
        if refreshTask != nil {
            if let workspaceIds {
                pendingWorkspaceIds.formUnion(workspaceIds)
            } else {
                pendingRefreshAll = true
                pendingWorkspaceIds.removeAll()
            }
#if DEBUG
            debugLog("ghpr.refresh.queue scope=\(workspaceIds == nil ? "all" : "workspace")")
#endif
            return
        }

        let tracked = host.trackedGHPRPullRequests()
        let trackedIds = Set(tracked.map(\.workspaceId))
        host.reconcileGHPRBadges(trackedWorkspaceIds: trackedIds)
        let selected = workspaceIds.map { ids in tracked.filter { ids.contains($0.workspaceId) } } ?? tracked
        guard !selected.isEmpty else {
            host.ghprRefreshStateDidChange(GHPRRefreshState())
#if DEBUG
            debugLog("ghpr.refresh.skip reason=noTrackedPullRequests tracked=\(tracked.count)")
#endif
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        host.ghprRefreshStateDidChange(GHPRRefreshState(isRefreshing: true))
#if DEBUG
        debugLog("ghpr.refresh.start selected=\(selected.count) tracked=\(tracked.count)")
#endif
        let fetcher = fetcher
        let debugLog = debugLog
        refreshTask = Task { @MainActor [weak self] in
            var firstError: GHPRRefreshErrorKind?
            let formatter = GHPRDisplayFormatter(
                displayItems: configuration.displayItems,
                jiraBaseURL: configuration.jiraBaseURL
            )
            for item in selected {
                guard !Task.isCancelled, self?.refreshGeneration == generation else {
                    self?.finishRefresh(generation: generation, error: nil, lastUpdated: nil)
                    return
                }
                do {
                    let context = try await fetcher.pullRequest(item.reference, socketPath: configuration.socketPath)
                    guard !Task.isCancelled, self?.refreshGeneration == generation else {
                        self?.finishRefresh(generation: generation, error: nil, lastUpdated: nil)
                        return
                    }
                    if let context {
                        host.applyGHPRBadges(formatter.badges(for: context), workspaceId: item.workspaceId)
                    } else {
                        host.clearGHPRBadges(workspaceId: item.workspaceId)
                    }
#if DEBUG
                    debugLog("ghpr.refresh.response workspace=\(item.workspaceId.uuidString.prefix(5)) found=\(context == nil ? 0 : 1)")
#endif
                } catch {
                    guard !Task.isCancelled, self?.refreshGeneration == generation else {
                        self?.finishRefresh(generation: generation, error: nil, lastUpdated: nil)
                        return
                    }
                    if firstError == nil {
                        firstError = (error as? GHPRSocketError)?.refreshKind ?? .requestFailed
                    }
#if DEBUG
                    debugLog("ghpr.refresh.error workspace=\(item.workspaceId.uuidString.prefix(5)) error=\(String(describing: error))")
#endif
                }
            }
            self?.finishRefresh(generation: generation, error: firstError, lastUpdated: Date())
        }
    }

    private func finishRefresh(
        generation: UInt64,
        error: GHPRRefreshErrorKind?,
        lastUpdated: Date?
    ) {
        guard refreshGeneration == generation else { return }
        refreshTask = nil
        host?.ghprRefreshStateDidChange(
            GHPRRefreshState(isRefreshing: false, lastUpdated: lastUpdated, error: error)
        )
#if DEBUG
        debugLog("ghpr.refresh.finish completed=\(lastUpdated == nil ? 0 : 1) error=\(error == nil ? 0 : 1)")
#endif
        runPendingRefreshIfNeeded()
    }

    private func runPendingRefreshIfNeeded() {
        if pendingRefreshAll {
            pendingRefreshAll = false
            pendingWorkspaceIds.removeAll()
            startRefresh(workspaceIds: nil)
        } else if !pendingWorkspaceIds.isEmpty {
            let workspaceIds = pendingWorkspaceIds
            pendingWorkspaceIds.removeAll()
            startRefresh(workspaceIds: workspaceIds)
        }
    }
}
