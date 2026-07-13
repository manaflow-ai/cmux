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

/// Runs the production PR scheduler and completion-authority state machine with
/// an isolated in-memory host and staged executor. It uses no GitHub network or
/// user workspace state.
public enum SidebarGitOwnerPerformanceExercise {
    @MainActor
    public static func run(
        requestCount: Int
    ) async throws -> SidebarGitOwnerPerformanceExerciseResult {
        try await run(
            requestCount: requestCount,
            runtimeMetricsRecorder: SidebarGitMetadataService.runtimeMetrics
        )
    }

    @MainActor
    static func run(
        requestCount: Int,
        runtimeMetricsRecorder: CmuxSidebarGitRuntimeMetrics
    ) async throws -> SidebarGitOwnerPerformanceExerciseResult {
        guard (2...8).contains(requestCount) else {
            throw SidebarGitOwnerPerformanceExerciseError.invalidRequestCount
        }

        let singleFlightHost = SidebarGitOwnerPerformanceHost(branch: "feature/single-flight")
        let singleFlightExecutor = SidebarGitOwnerPerformanceExecutor()
        let singleFlightService = makeService(
            host: singleFlightHost,
            executor: singleFlightExecutor,
            runtimeMetricsRecorder: runtimeMetricsRecorder
        )
        singleFlightService.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        await singleFlightExecutor.waitForFetchCount(1)
        for _ in 1..<requestCount {
            singleFlightService.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        }
        await singleFlightExecutor.releaseNextFetch()
        await singleFlightHost.waitForBadgeApplyCount(1)
        let singleFlightApplyCount = singleFlightHost.badgeApplyCount
        singleFlightService.resetWorkspacePullRequestRefreshState()

        let staleHost = SidebarGitOwnerPerformanceHost(branch: "feature/stale-a")
        let staleExecutor = SidebarGitOwnerPerformanceExecutor()
        let staleService = makeService(
            host: staleHost,
            executor: staleExecutor,
            runtimeMetricsRecorder: runtimeMetricsRecorder
        )
        staleService.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        await staleExecutor.waitForFetchCount(1)
        staleHost.branch = "feature/stale-b"
        staleService.seedWorkspacePullRequestRefreshIfNeeded(
            workspaceId: staleHost.workspaceId,
            panelId: staleHost.panelId,
            directory: staleHost.directory,
            branch: staleHost.branch,
            reason: "localGitProbe"
        )
        await staleExecutor.releaseNextFetch()
        await staleExecutor.waitForFetchCount(2)
        let staleApplyCountBeforeFollowUp = staleHost.badgeApplyCount
        await staleExecutor.releaseNextFetch()
        await staleHost.waitForBadgeApplyCount(1)
        let staleFinalApplyCount = staleHost.badgeApplyCount
        let staleFinalBranch = staleHost.badge?.branch
        staleService.resetWorkspacePullRequestRefreshState()

        return SidebarGitOwnerPerformanceExerciseResult(
            requestCount: requestCount,
            singleFlightApplyCount: singleFlightApplyCount,
            staleApplyCountBeforeFollowUp: staleApplyCountBeforeFollowUp,
            staleFinalApplyCount: staleFinalApplyCount,
            staleFinalBranch: staleFinalBranch
        )
    }

    @MainActor
    private static func makeService(
        host: SidebarGitOwnerPerformanceHost,
        executor: SidebarGitOwnerPerformanceExecutor,
        runtimeMetricsRecorder: CmuxSidebarGitRuntimeMetrics
    ) -> PullRequestPollService {
        let service = PullRequestPollService(
            refreshExecutor: executor,
            clock: SystemGitPollClock()
        )
        service.runtimeMetricsRecorder = runtimeMetricsRecorder
        service.attach(host: host)
        return service
    }
}

enum SidebarGitOwnerPerformanceExerciseError: Error {
    case invalidRequestCount
}
