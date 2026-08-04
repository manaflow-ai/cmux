import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct PaneMapReorderStateTests {
    @Test func beginMoveCapturesBaseLayoutRevision() {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["a", "b", "c"],
            authoritativeRevision: 7
        )

        let request = state.beginMove(from: 0, to: 2)

        #expect(request?.baseLayoutRevision == 7)
        #expect(request?.orderedPaneIDs == ["b", "c", "a"])
    }

    @Test func lowerRevisionReconcileDoesNotRollBackAuthority() {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["b", "a", "c"],
            authoritativeRevision: 5
        )

        // A delayed pre-reorder workspace-list response arrives after newer
        // authority already applied.
        state.reconcile(authoritativePaneIDs: ["a", "b", "c"], authoritativeRevision: 4)

        #expect(state.authoritativePaneIDs == ["b", "a", "c"])
        #expect(state.authoritativeRevision == 5)
        #expect(state.visiblePaneIDs == ["b", "a", "c"])
    }

    @Test func lowerRevisionDoesNotCompletePendingMutation() {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["a", "b", "c"],
            authoritativeRevision: 5
        )
        let request = state.beginMove(from: 0, to: 1)
        #expect(request != nil)

        // Stale response from before the drag must neither count as the
        // mutation's authoritative refresh nor overwrite the optimistic order.
        state.reconcile(authoritativePaneIDs: ["a", "b", "c"], authoritativeRevision: 4)
        let completion = state.complete(requestID: request!.id, succeeded: true)

        #expect(completion == .awaitingAuthority)
        #expect(state.isMutationPending)
        #expect(state.visiblePaneIDs == ["b", "a", "c"])

        // The genuinely newer authority then completes the mutation.
        state.reconcile(authoritativePaneIDs: ["b", "a", "c"], authoritativeRevision: 6)
        #expect(!state.isMutationPending)
        #expect(state.visiblePaneIDs == ["b", "a", "c"])
    }

    @Test func equalRevisionReconcileStillUpdatesContentWithoutPendingMutation() {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["a", "b"],
            authoritativeRevision: 3
        )

        state.reconcile(authoritativePaneIDs: ["a", "b"], authoritativeRevision: 3)

        #expect(state.visiblePaneIDs == ["a", "b"])
        #expect(state.authoritativeRevision == 3)
    }

    @Test func newerRevisionRollsBackAbandonedOptimisticOrder() {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["a", "b", "c"],
            authoritativeRevision: 5
        )
        let request = state.beginMove(from: 0, to: 2)
        #expect(request != nil)

        _ = state.complete(requestID: request!.id, succeeded: false)

        #expect(state.visiblePaneIDs == ["a", "b", "c"])
        #expect(!state.isMutationPending)
    }
}
