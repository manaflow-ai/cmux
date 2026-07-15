import Foundation

/// Behavioral result from the isolated pull-request ownership exercise.
/// Counter values remain in ``CmuxSidebarGitRuntimeMetricsSnapshot`` so callers
/// must cross-check behavior against the normal production record sites.
public struct SidebarGitOwnerPerformanceExerciseResult: Sendable {
    public let requestCount: Int
    public let singleFlightApplyCount: Int
    public let staleApplyCountBeforeFollowUp: Int
    public let staleFinalApplyCount: Int
    public let staleFinalBranch: String?
}

struct SidebarGitOwnerPerformanceExerciseFault: OptionSet, Sendable {
    let rawValue: Int

    static let missingFetchSignal = Self(rawValue: 1 << 0)
    static let missingBadgeApplySignal = Self(rawValue: 1 << 1)
}

struct SidebarGitOwnerPerformanceCleanupSnapshot: Equatable, Sendable {
    let pendingFetchGateCount: Int
    let pendingFetchWaiterCount: Int
    let pendingBadgeWaiterCount: Int

    var isEmpty: Bool {
        pendingFetchGateCount == 0 &&
            pendingFetchWaiterCount == 0 &&
            pendingBadgeWaiterCount == 0
    }
}

actor SidebarGitOwnerPerformanceCleanupProbe {
    private(set) var snapshots: [SidebarGitOwnerPerformanceCleanupSnapshot] = []

    func record(_ snapshot: SidebarGitOwnerPerformanceCleanupSnapshot) {
        snapshots.append(snapshot)
    }
}

/// Runs the production PR scheduler and completion-authority state machine with
/// an isolated in-memory host and staged executor. It uses no GitHub network or
/// user workspace state.
public struct SidebarGitOwnerPerformanceExercise: Sendable {
    private let runtimeMetricsRecorder: CmuxSidebarGitRuntimeMetrics
    private let deadlineClock: any GitPollClock
    private let lifecycleDeadline: Duration
    private let fault: SidebarGitOwnerPerformanceExerciseFault
    private let cleanupProbe: SidebarGitOwnerPerformanceCleanupProbe?

    /// Creates an exercise with the production metrics owner and system clock.
    @MainActor
    public init() {
        runtimeMetricsRecorder = SidebarGitMetadataService.runtimeMetrics
        deadlineClock = SystemGitPollClock()
        lifecycleDeadline = .seconds(10)
        fault = []
        cleanupProbe = nil
    }

    @MainActor
    init(
        runtimeMetricsRecorder: CmuxSidebarGitRuntimeMetrics,
        deadlineClock: any GitPollClock = SystemGitPollClock(),
        lifecycleDeadline: Duration = .seconds(10),
        fault: SidebarGitOwnerPerformanceExerciseFault = [],
        cleanupProbe: SidebarGitOwnerPerformanceCleanupProbe? = nil
    ) {
        self.runtimeMetricsRecorder = runtimeMetricsRecorder
        self.deadlineClock = deadlineClock
        self.lifecycleDeadline = lifecycleDeadline
        self.fault = fault
        self.cleanupProbe = cleanupProbe
    }

    @MainActor
    public func run(
        requestCount: Int
    ) async throws -> SidebarGitOwnerPerformanceExerciseResult {
        guard (2...8).contains(requestCount) else {
            throw SidebarGitOwnerPerformanceExerciseError.invalidRequestCount
        }
        try Task.checkCancellation()

        let singleFlightHost = SidebarGitOwnerPerformanceHost(
            branch: "feature/single-flight",
            suppressesBadgeApplySignal: fault.contains(.missingBadgeApplySignal)
        )
        let singleFlightExecutor = SidebarGitOwnerPerformanceExecutor(
            suppressesFetchCountSignal: fault.contains(.missingFetchSignal)
        )
        let singleFlightService = makeService(
            host: singleFlightHost,
            executor: singleFlightExecutor
        )
        let singleFlightApplyCount: Int
        do {
            singleFlightService.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
            try await waitForLifecycleSignal(
                clock: deadlineClock,
                deadline: lifecycleDeadline
            ) {
                try await singleFlightExecutor.waitForFetchCount(1)
            }
            for _ in 1..<requestCount {
                singleFlightService.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
            }
            await singleFlightExecutor.releaseNextFetch()
            try await waitForLifecycleSignal(
                clock: deadlineClock,
                deadline: lifecycleDeadline
            ) {
                try await singleFlightHost.waitForBadgeApplyCount(1)
            }
            singleFlightApplyCount = singleFlightHost.badgeApplyCount
        } catch {
            try await cleanup(
                service: singleFlightService,
                host: singleFlightHost,
                executor: singleFlightExecutor,
                probe: cleanupProbe
            )
            throw error
        }
        try await cleanup(
            service: singleFlightService,
            host: singleFlightHost,
            executor: singleFlightExecutor,
            probe: cleanupProbe
        )
        try Task.checkCancellation()

        let staleHost = SidebarGitOwnerPerformanceHost(branch: "feature/stale-a")
        let staleExecutor = SidebarGitOwnerPerformanceExecutor()
        let staleService = makeService(
            host: staleHost,
            executor: staleExecutor
        )
        let staleApplyCountBeforeFollowUp: Int
        let staleFinalApplyCount: Int
        let staleFinalBranch: String?
        do {
            staleService.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
            try await waitForLifecycleSignal(
                clock: deadlineClock,
                deadline: lifecycleDeadline
            ) {
                try await staleExecutor.waitForFetchCount(1)
            }
            staleHost.branch = "feature/stale-b"
            staleService.seedWorkspacePullRequestRefreshIfNeeded(
                workspaceId: staleHost.workspaceId,
                panelId: staleHost.panelId,
                directory: staleHost.directory,
                branch: staleHost.branch,
                reason: "localGitProbe"
            )
            await staleExecutor.releaseNextFetch()
            try await waitForLifecycleSignal(
                clock: deadlineClock,
                deadline: lifecycleDeadline
            ) {
                try await staleExecutor.waitForFetchCount(2)
            }
            staleApplyCountBeforeFollowUp = staleHost.badgeApplyCount
            await staleExecutor.releaseNextFetch()
            try await waitForLifecycleSignal(
                clock: deadlineClock,
                deadline: lifecycleDeadline
            ) {
                try await staleHost.waitForBadgeApplyCount(1)
            }
            staleFinalApplyCount = staleHost.badgeApplyCount
            staleFinalBranch = staleHost.badge?.branch
        } catch {
            try await cleanup(
                service: staleService,
                host: staleHost,
                executor: staleExecutor,
                probe: cleanupProbe
            )
            throw error
        }
        try await cleanup(
            service: staleService,
            host: staleHost,
            executor: staleExecutor,
            probe: cleanupProbe
        )

        return SidebarGitOwnerPerformanceExerciseResult(
            requestCount: requestCount,
            singleFlightApplyCount: singleFlightApplyCount,
            staleApplyCountBeforeFollowUp: staleApplyCountBeforeFollowUp,
            staleFinalApplyCount: staleFinalApplyCount,
            staleFinalBranch: staleFinalBranch
        )
    }

    @MainActor
    private func makeService(
        host: SidebarGitOwnerPerformanceHost,
        executor: SidebarGitOwnerPerformanceExecutor
    ) -> PullRequestPollService {
        let service = PullRequestPollService(
            refreshExecutor: executor,
            clock: SystemGitPollClock()
        )
        service.runtimeMetricsRecorder = runtimeMetricsRecorder
        service.attach(host: host)
        return service
    }

    private func waitForLifecycleSignal(
        clock: any GitPollClock,
        deadline: Duration,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await clock.sleep(for: deadline)
                try Task.checkCancellation()
                throw SidebarGitOwnerPerformanceExerciseError.lifecycleDeadlineExceeded
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw SidebarGitOwnerPerformanceExerciseError.lifecycleDeadlineExceeded
            }
        }
        try Task.checkCancellation()
    }

    @MainActor
    private func cleanup(
        service: PullRequestPollService,
        host: SidebarGitOwnerPerformanceHost,
        executor: SidebarGitOwnerPerformanceExecutor,
        probe: SidebarGitOwnerPerformanceCleanupProbe?
    ) async throws {
        service.resetWorkspacePullRequestRefreshState()
        await executor.cancelAllPending()
        host.cancelAllPendingBadgeWaits()
        await Task.yield()
        let snapshot = SidebarGitOwnerPerformanceCleanupSnapshot(
            pendingFetchGateCount: await executor.pendingFetchGateCount,
            pendingFetchWaiterCount: await executor.pendingFetchWaiterCount,
            pendingBadgeWaiterCount: host.pendingBadgeWaiterCount
        )
        await probe?.record(snapshot)
        guard snapshot.isEmpty else {
            throw SidebarGitOwnerPerformanceExerciseError.cleanupFailed
        }
    }
}

enum SidebarGitOwnerPerformanceExerciseError: Error {
    case invalidRequestCount
    case lifecycleDeadlineExceeded
    case cleanupFailed
}
