import CmuxGit
import Foundation
import Testing
@testable import CmuxSidebarGit

@MainActor
@Suite struct SidebarGitOwnerPerformanceExerciseTests {
    @Test(.timeLimit(.minutes(1)))
    func exerciseUsesNormalRequestJoinFetchRejectAndApplySites() async throws {
        let metrics = CmuxSidebarGitRuntimeMetrics()
        metrics.reset(enable: true)

        let result = try await SidebarGitOwnerPerformanceExercise.run(
            requestCount: 4,
            runtimeMetricsRecorder: metrics
        )
        let snapshot = metrics.snapshot()

        #expect(result.requestCount == 4)
        #expect(result.singleFlightApplyCount == 1)
        #expect(result.staleApplyCountBeforeFollowUp == 0)
        #expect(result.staleFinalApplyCount == 1)
        #expect(result.staleFinalBranch == "feature/stale-b")
        #expect(snapshot.pullRequestSeedCount == 1)
        #expect(snapshot.pullRequestTraversalCount == 3)
        #expect(snapshot.pullRequestRefreshRequestCount == 6)
        #expect(snapshot.pullRequestTaskStartedCount == 3)
        #expect(snapshot.pullRequestTaskJoinedCount == 3)
        #expect(snapshot.pullRequestRepoFetchCount == 3)
        #expect(snapshot.pullRequestStaleCompletionRejectedOffMainCount == 1)
        #expect(snapshot.pullRequestMainActorApplyEnteredCount == 2)
        #expect(snapshot.pullRequestFollowUpStartedCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingGatedFetchReturnsWithoutProducingAResult() async throws {
        let executor = SidebarGitOwnerPerformanceExecutor()
        let resolution = await executor.resolveCandidateSeeds([
            WorkspacePullRequestCandidateSeed(
                workspaceId: UUID(),
                panelId: UUID(),
                branch: "feature/cancel-fetch",
                directory: "/isolated/owner-proof"
            ),
        ])
        let fetchTask = Task {
            await executor.fetchRepoResults(
                candidateResolution: resolution,
                cacheBySlug: [:],
                now: Date(),
                allowCachedResults: false
            )
        }

        try await executor.waitForFetchCount(1)
        while await executor.pendingFetchGateCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        fetchTask.cancel()

        #expect(await fetchTask.value.isEmpty)
        #expect(await executor.pendingFetchGateCount == 0)
        #expect(await executor.pendingFetchWaiterCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingBadgeWaitThrowsCancellation() async throws {
        let host = SidebarGitOwnerPerformanceHost(branch: "feature/cancel-badge")
        let waitTask = Task { @MainActor in
            do {
                try await host.waitForBadgeApplyCount(1)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        while host.pendingBadgeWaiterCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        waitTask.cancel()

        #expect(await waitTask.value)
        #expect(host.pendingBadgeWaiterCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingFetchSignalHitsInternalDeadlineAndCleansUp() async throws {
        let clock = ManualGitPollClock()
        let probe = SidebarGitOwnerPerformanceCleanupProbe()
        let metrics = CmuxSidebarGitRuntimeMetrics()
        metrics.reset(enable: true)
        let task = Task { @MainActor in
            try await SidebarGitOwnerPerformanceExercise.run(
                requestCount: 4,
                runtimeMetricsRecorder: metrics,
                deadlineClock: clock,
                lifecycleDeadline: .seconds(1),
                fault: .missingFetchSignal,
                cleanupProbe: probe
            )
        }

        #expect(await clock.waitForRecordedDuration(1, count: 1))
        #expect(await clock.resumeFirst(duration: 1))
        do {
            _ = try await task.value
            Issue.record("Expected the missing fetch signal to hit its internal deadline")
        } catch SidebarGitOwnerPerformanceExerciseError.lifecycleDeadlineExceeded {
            // Expected.
        }

        #expect(await probe.snapshots == [.empty])
        #expect(await clock.pendingSleeperCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingBadgeApplySignalHitsInternalDeadlineAndCleansUp() async throws {
        let clock = ManualGitPollClock()
        let probe = SidebarGitOwnerPerformanceCleanupProbe()
        let metrics = CmuxSidebarGitRuntimeMetrics()
        metrics.reset(enable: true)
        let task = Task { @MainActor in
            try await SidebarGitOwnerPerformanceExercise.run(
                requestCount: 4,
                runtimeMetricsRecorder: metrics,
                deadlineClock: clock,
                lifecycleDeadline: .seconds(1),
                fault: .missingBadgeApplySignal,
                cleanupProbe: probe
            )
        }

        #expect(await clock.waitForRecordedDuration(1, count: 2))
        #expect(await clock.resumeFirst(duration: 1))
        do {
            _ = try await task.value
            Issue.record("Expected the missing apply signal to hit its internal deadline")
        } catch SidebarGitOwnerPerformanceExerciseError.lifecycleDeadlineExceeded {
            // Expected.
        }

        #expect(await probe.snapshots == [.empty])
        #expect(await clock.pendingSleeperCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingFullExerciseCancelsEveryPendingWait() async throws {
        let clock = ManualGitPollClock()
        let probe = SidebarGitOwnerPerformanceCleanupProbe()
        let metrics = CmuxSidebarGitRuntimeMetrics()
        metrics.reset(enable: true)
        let task = Task { @MainActor in
            try await SidebarGitOwnerPerformanceExercise.run(
                requestCount: 4,
                runtimeMetricsRecorder: metrics,
                deadlineClock: clock,
                lifecycleDeadline: .seconds(1),
                fault: .missingFetchSignal,
                cleanupProbe: probe
            )
        }

        #expect(await clock.waitForRecordedDuration(1, count: 1))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected full exercise cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await probe.snapshots == [.empty])
        #expect(await clock.pendingSleeperCount == 0)
    }
}

private extension SidebarGitOwnerPerformanceCleanupSnapshot {
    static let empty = Self(
        pendingFetchGateCount: 0,
        pendingFetchWaiterCount: 0,
        pendingBadgeWaiterCount: 0
    )
}
