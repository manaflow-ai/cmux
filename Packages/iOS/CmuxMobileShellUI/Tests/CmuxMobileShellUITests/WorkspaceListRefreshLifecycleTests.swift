#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite("Workspace list refresh lifecycle")
struct WorkspaceListRefreshLifecycleTests {
    @Test("suppresses snapshots until the visible collapse completes")
    func suppressesSnapshotsUntilCollapseCompletes() throws {
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
        let startedCollapseID = lifecycle.snapshotApplyCompleted(applyID)
        let collapseID = try #require(startedCollapseID)
        #expect(lifecycle.suppressesSnapshotAnimations)

        let collapseStarted = lifecycle.collapseStarted(collapseID)
        #expect(collapseStarted)
        #expect(lifecycle.suppressesSnapshotAnimations)

        let collapseCompleted = lifecycle.collapseCompleted(collapseID)
        #expect(collapseCompleted)
        #expect(!lifecycle.suppressesSnapshotAnimations)
    }

    @Test("requires the matching collapse token at start and completion")
    func requiresMatchingCollapseToken() throws {
        var lifecycle = WorkspaceListRefreshLifecycle()
        let startedFirstRefreshID = lifecycle.begin(currentGeneration: 0)
        let firstRefreshID = try #require(startedFirstRefreshID)
        let firstActionCompleted = lifecycle.refreshActionCompleted(firstRefreshID)
        #expect(firstActionCompleted)
        let startedFirstApplyID = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 1
        )
        let firstApplyID = try #require(startedFirstApplyID)
        let startedFirstCollapseID = lifecycle.snapshotApplyCompleted(firstApplyID)
        let firstCollapseID = try #require(startedFirstCollapseID)

        lifecycle.reset()
        let startedSecondRefreshID = lifecycle.begin(currentGeneration: 1)
        let secondRefreshID = try #require(startedSecondRefreshID)
        let secondActionCompleted = lifecycle.refreshActionCompleted(secondRefreshID)
        #expect(secondActionCompleted)
        let startedSecondApplyID = lifecycle.snapshotApplyStarted(
            refreshCompletionGeneration: 2
        )
        let secondApplyID = try #require(startedSecondApplyID)
        let startedSecondCollapseID = lifecycle.snapshotApplyCompleted(secondApplyID)
        let secondCollapseID = try #require(startedSecondCollapseID)
        #expect(secondCollapseID != firstCollapseID)

        let staleCollapseStarted = lifecycle.collapseStarted(firstCollapseID)
        #expect(!staleCollapseStarted)
        #expect(lifecycle.suppressesSnapshotAnimations)
        let secondCollapseStarted = lifecycle.collapseStarted(secondCollapseID)
        #expect(secondCollapseStarted)
        let staleCollapseCompleted = lifecycle.collapseCompleted(firstCollapseID)
        #expect(!staleCollapseCompleted)
        #expect(lifecycle.suppressesSnapshotAnimations)
        let secondCollapseCompleted = lifecycle.collapseCompleted(secondCollapseID)
        #expect(secondCollapseCompleted)
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

        let staleCollapseID = lifecycle.snapshotApplyCompleted(firstApplyID)
        #expect(staleCollapseID == nil)
        let latestCollapseID = lifecycle.snapshotApplyCompleted(latestApplyID)
        #expect(latestCollapseID != nil)

        lifecycle.reset()
        let startedSecondRefreshID = lifecycle.begin(currentGeneration: 1)
        let secondRefreshID = try #require(startedSecondRefreshID)
        #expect(secondRefreshID != firstRefreshID)
        let staleRefreshCompleted = lifecycle.refreshActionCompleted(firstRefreshID)
        #expect(!staleRefreshCompleted)
        let staleRefreshCancelled = lifecycle.cancelRefresh(firstRefreshID)
        #expect(!staleRefreshCancelled)
        #expect(lifecycle.suppressesSnapshotAnimations)
        let activeRefreshCancelled = lifecycle.cancelRefresh(secondRefreshID)
        #expect(activeRefreshCancelled)
        #expect(!lifecycle.suppressesSnapshotAnimations)
    }
}
#endif
