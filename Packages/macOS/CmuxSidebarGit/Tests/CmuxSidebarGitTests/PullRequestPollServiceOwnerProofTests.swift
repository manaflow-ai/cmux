import Foundation
import Testing
@testable import CmuxSidebarGit

@MainActor
@Suite struct PullRequestPollServiceOwnerProofTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        executor: any PullRequestRefreshExecuting
    ) -> PullRequestPollService {
        let service = PullRequestPollService(
            refreshExecutor: executor,
            clock: ManualGitPollClock()
        )
        let metrics = CmuxSidebarGitRuntimeMetrics()
        metrics.reset(enable: true)
        service.runtimeMetricsRecorder = metrics
        service.attach(host: host)
        return service
    }

    @Test(.timeLimit(.minutes(1)))
    func equivalentOverlappingRefreshesJoinBeforeTraversalAndRunOneRepoFetch() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: false
        )
        let executor = GatedPullRequestRefreshExecutor()
        let service = makeService(host: host, executor: executor)

        let requestCount = 8
        service.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        await executor.waitForFetchCount(1)
        for _ in 1..<requestCount {
            service.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        }

        let beforeRelease = service.runtimeMetricsRecorder.snapshot()
        #expect(beforeRelease.pullRequestRefreshRequestCount == requestCount)
        #expect(beforeRelease.pullRequestTaskStartedCount == 1)
        #expect(beforeRelease.pullRequestTaskJoinedCount == requestCount - 1)
        #expect(beforeRelease.pullRequestRepoFetchCount == 1)
        #expect(beforeRelease.pullRequestMainActorApplyEnteredCount == 0)
        #expect(host.orderedWorkspaceIdsReadCount == 1)
        #expect(host.panelGitBranchPanelIdsReadCount == 1)
        #expect(host.panelPullRequestPanelIdsReadCount == 1)
        #expect(await executor.fetchCount == 1)

        let events = host.projectionEvents()
        await executor.releaseNextFetch()
        for await event in events {
            if case .pullRequestBadge(workspaceId, panelId, _) = event {
                break
            }
        }

        let afterApply = service.runtimeMetricsRecorder.snapshot()
        #expect(afterApply.pullRequestMainActorApplyEnteredCount == 1)
        #expect(afterApply.pullRequestFollowUpStartedCount == 0)
        service.resetWorkspacePullRequestRefreshState()
    }

    @Test(.timeLimit(.minutes(1)))
    func sourceChangeRejectsCompletionOffMainAndStartsExactlyOneFollowUp() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/a",
            isDirty: false
        )
        let executor = GatedPullRequestRefreshExecutor()
        let service = makeService(host: host, executor: executor)

        service.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        await executor.waitForFetchCount(1)

        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/b",
            isDirty: false
        )
        service.seedWorkspacePullRequestRefreshIfNeeded(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: "/tmp/repo",
            branch: "feature/b",
            reason: "localGitProbe"
        )

        await executor.releaseNextFetch()
        await executor.waitForFetchCount(2)

        let rejected = service.runtimeMetricsRecorder.snapshot()
        #expect(rejected.pullRequestStaleCompletionRejectedOffMainCount == 1)
        #expect(rejected.pullRequestMainActorApplyEnteredCount == 0)
        #expect(rejected.pullRequestFollowUpStartedCount == 1)
        #expect(rejected.pullRequestTaskStartedCount == 2)
        #expect(rejected.pullRequestRepoFetchCount == 2)
        #expect(await executor.fetchCount == 2)
        #expect(!host.events.contains { event in
            if case .pullRequestBadge = event { return true }
            return false
        })

        let events = host.projectionEvents()
        await executor.releaseNextFetch()
        for await event in events {
            if case .pullRequestBadge(workspaceId, panelId, let appliedBadge) = event {
                #expect(appliedBadge.branch == "feature/b")
                break
            }
        }

        let applied = service.runtimeMetricsRecorder.snapshot()
        #expect(applied.pullRequestMainActorApplyEnteredCount == 1)
        #expect(applied.pullRequestFollowUpStartedCount == 1)
        #expect(await executor.fetchCount == 2)
        service.resetWorkspacePullRequestRefreshState()
    }

    @Test(.timeLimit(.minutes(1)))
    func commandRefreshForIdlePanelSurvivesAnotherPanelsActiveRefresh() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelAId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let panelBId = UUID()
        host.workspaces[0].state.panels[panelBId] = .init(directory: "/tmp/repo")
        host.workspaces[0].state.panels[panelAId]?.branch = SidebarPanelGitBranch(
            branch: "feature/a",
            isDirty: false
        )
        host.workspaces[0].state.panels[panelBId]?.branch = SidebarPanelGitBranch(
            branch: "feature/b",
            isDirty: false
        )
        let executor = GatedPullRequestRefreshExecutor()
        let service = makeService(host: host, executor: executor)
        let panelBKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelBId)
        service.workspacePullRequestNextPollAtByKey[panelBKey] = .distantFuture

        service.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        await executor.waitForFetchCount(1)

        service.scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelBId,
            reason: "commandHint:merge"
        )
        #expect(service.workspacePullRequestPendingRefreshRequest?.shouldBypassRepoCache == true)

        await executor.releaseNextFetch()
        await executor.waitForFetchCount(2)

        let betweenFetches = service.runtimeMetricsRecorder.snapshot()
        #expect(betweenFetches.pullRequestStaleCompletionRejectedOffMainCount == 0)
        #expect(betweenFetches.pullRequestFollowUpStartedCount == 1)
        #expect(betweenFetches.pullRequestTaskStartedCount == 2)
        #expect(await executor.allowCachedResultsRequests == [true, false])

        let events = host.projectionEvents()
        await executor.releaseNextFetch()
        for await event in events {
            if case .pullRequestBadge(workspaceId, panelBId, let badge) = event {
                #expect(badge.branch == "feature/b")
                break
            }
        }

        let applied = service.runtimeMetricsRecorder.snapshot()
        #expect(applied.pullRequestFollowUpStartedCount == 1)
        #expect(await executor.fetchCount == 2)
        service.resetWorkspacePullRequestRefreshState()
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectedBatchPreservesSurvivingPanelsCacheBypassIntent() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelAId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let panelBId = UUID()
        host.workspaces[0].state.panels[panelBId] = .init(directory: "/tmp/repo")
        host.workspaces[0].state.panels[panelAId]?.branch = SidebarPanelGitBranch(
            branch: "feature/a",
            isDirty: false
        )
        host.workspaces[0].state.panels[panelBId]?.branch = SidebarPanelGitBranch(
            branch: "feature/b",
            isDirty: false
        )
        let executor = GatedPullRequestRefreshExecutor()
        let service = makeService(host: host, executor: executor)
        let panelBKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelBId)

        service.seedWorkspacePullRequestRefreshIfNeeded(
            workspaceId: workspaceId,
            panelId: panelAId,
            directory: "/tmp/repo",
            branch: "feature/a",
            reason: "localGitProbe"
        )
        service.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
        await executor.waitForFetchCount(1)

        host.workspaces[0].state.panels.removeValue(forKey: panelBId)
        service.clearWorkspacePullRequestTracking(
            workspaceId: workspaceId,
            panelId: panelBId
        )
        await executor.releaseNextFetch()
        await executor.waitForFetchCount(2)

        #expect(await executor.allowCachedResultsRequests == [false, false])
        #expect(service.workspacePullRequestProbeStateByKey[panelBKey] == nil)

        await executor.releaseNextFetch()
        while service.workspacePullRequestRefreshTask != nil {
            await Task.yield()
        }
        service.resetWorkspacePullRequestRefreshState()
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectedBatchPreservesBatchWideCacheBypassIntent() async throws {
        let host = RecordingSidebarGitHost()
        host.pollingEnabled = true
        let (workspaceId, panelAId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let panelBId = UUID()
        host.workspaces[0].state.panels[panelBId] = .init(directory: "/tmp/repo")
        host.workspaces[0].state.panels[panelAId]?.branch = SidebarPanelGitBranch(
            branch: "feature/a",
            isDirty: false
        )
        host.workspaces[0].state.panels[panelBId]?.branch = SidebarPanelGitBranch(
            branch: "feature/b",
            isDirty: false
        )
        let executor = GatedPullRequestRefreshExecutor()
        let service = makeService(host: host, executor: executor)

        service.refreshTrackedWorkspacePullRequestsIfNeeded(
            reason: "timer",
            allowCachedResultsOverride: false
        )
        await executor.waitForFetchCount(1)

        host.workspaces[0].state.panels.removeValue(forKey: panelBId)
        service.clearWorkspacePullRequestTracking(
            workspaceId: workspaceId,
            panelId: panelBId
        )
        await executor.releaseNextFetch()
        await executor.waitForFetchCount(2)

        #expect(await executor.allowCachedResultsRequests == [false, false])

        await executor.releaseNextFetch()
        while service.workspacePullRequestRefreshTask != nil {
            await Task.yield()
        }
        service.resetWorkspacePullRequestRefreshState()
    }
}
