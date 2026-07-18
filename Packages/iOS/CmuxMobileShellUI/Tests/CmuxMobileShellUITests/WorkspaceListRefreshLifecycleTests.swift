#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite("Workspace list refresh lifecycle")
struct WorkspaceListRefreshLifecycleTests {
    @Test("suppresses snapshots until the native collapse settles")
    func suppressesSnapshotsUntilCollapseSettles() throws {
        var lifecycle = WorkspaceListRefreshLifecycle()
        #expect(!lifecycle.suppressesSnapshotAnimations)

        let startedRefreshID = lifecycle.begin(currentGeneration: 10)
        let refreshID = try #require(startedRefreshID)
        #expect(lifecycle.suppressesSnapshotAnimations)
        let applyDuringRefresh = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 10
        )
        #expect(applyDuringRefresh == nil)

        let actionCompleted = lifecycle.refreshActionCompleted(refreshID)
        #expect(actionCompleted)
        let staleApply = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 10
        )
        #expect(staleApply == nil)
        let startedApplyID = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 11
        )
        let applyID = try #require(startedApplyID)
        let applyCompleted = lifecycle.snapshotApplyCompleted(applyID)
        #expect(applyCompleted)
        #expect(lifecycle.suppressesSnapshotAnimations)

        lifecycle.observeCollapse(
            refreshControlIsRefreshing: false,
            scrollViewIsTracking: false,
            contentOffsetY: -20,
            restingTopY: -20
        )
        #expect(!lifecycle.suppressesSnapshotAnimations)
    }

    @Test("requires every native collapse condition to settle")
    func requiresEveryCollapseConditionToSettle() throws {
        var lifecycle = WorkspaceListRefreshLifecycle()
        let startedRefreshID = lifecycle.begin(currentGeneration: 0)
        let refreshID = try #require(startedRefreshID)
        let actionCompleted = lifecycle.refreshActionCompleted(refreshID)
        #expect(actionCompleted)
        let startedApplyID = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 1
        )
        let applyID = try #require(startedApplyID)
        let applyCompleted = lifecycle.snapshotApplyCompleted(applyID)
        #expect(applyCompleted)

        lifecycle.observeCollapse(
            refreshControlIsRefreshing: true,
            scrollViewIsTracking: false,
            contentOffsetY: 0,
            restingTopY: 0
        )
        #expect(lifecycle.suppressesSnapshotAnimations)

        lifecycle.observeCollapse(
            refreshControlIsRefreshing: false,
            scrollViewIsTracking: true,
            contentOffsetY: 0,
            restingTopY: 0
        )
        #expect(lifecycle.suppressesSnapshotAnimations)

        lifecycle.observeCollapse(
            refreshControlIsRefreshing: false,
            scrollViewIsTracking: false,
            contentOffsetY: -1,
            restingTopY: 0
        )
        #expect(lifecycle.suppressesSnapshotAnimations)

        lifecycle.observeCollapse(
            refreshControlIsRefreshing: false,
            scrollViewIsTracking: false,
            contentOffsetY: 0.5,
            restingTopY: 0
        )
        #expect(!lifecycle.suppressesSnapshotAnimations)
    }

    @Test("ignores stale refresh and snapshot completions")
    func ignoresStaleCompletions() throws {
        var lifecycle = WorkspaceListRefreshLifecycle()
        let startedFirstRefreshID = lifecycle.begin(currentGeneration: 0)
        let firstRefreshID = try #require(startedFirstRefreshID)
        let firstActionCompleted = lifecycle.refreshActionCompleted(firstRefreshID)
        #expect(firstActionCompleted)
        let startedFirstApplyID = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 1
        )
        let firstApplyID = try #require(startedFirstApplyID)
        let startedLatestApplyID = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 1
        )
        let latestApplyID = try #require(startedLatestApplyID)

        let staleApplyCompleted = lifecycle.snapshotApplyCompleted(firstApplyID)
        #expect(!staleApplyCompleted)
        let latestApplyCompleted = lifecycle.snapshotApplyCompleted(latestApplyID)
        #expect(latestApplyCompleted)

        lifecycle.reset()
        let startedSecondRefreshID = lifecycle.begin(currentGeneration: 1)
        let secondRefreshID = try #require(startedSecondRefreshID)
        #expect(secondRefreshID != firstRefreshID)
        let staleRefreshCompleted = lifecycle.refreshActionCompleted(firstRefreshID)
        #expect(!staleRefreshCompleted)
        #expect(lifecycle.suppressesSnapshotAnimations)
    }
}
#endif
