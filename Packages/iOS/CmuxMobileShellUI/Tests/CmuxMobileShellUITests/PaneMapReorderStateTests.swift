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

    @Test func failureRollsBackToTheLatestAuthoritativeOrder() throws {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["left", "middle", "right"],
            authoritativeRevision: 10
        )

        let pendingRequest = state.beginMove(from: 0, to: 2)
        let request = try #require(pendingRequest)
        #expect(state.visiblePaneIDs == ["middle", "right", "left"])

        state.reconcile(
            authoritativePaneIDs: ["left", "right", "middle"],
            authoritativeRevision: 11
        )
        #expect(
            state.visiblePaneIDs == ["middle", "right", "left"],
            "An in-flight optimistic move must remain stable while the Mac refresh arrives"
        )

        #expect(state.complete(requestID: request.id, succeeded: false) == .rolledBack)
        #expect(state.visiblePaneIDs == ["left", "right", "middle"])
        #expect(!state.isMutationPending)
    }

    @Test func successWaitsForAndThenUsesTheAuthoritativeMacOrder() throws {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["one", "two", "three"],
            authoritativeRevision: 20
        )

        let pendingRequest = state.beginMove(from: 2, to: 0)
        let request = try #require(pendingRequest)
        #expect(request.orderedPaneIDs == ["three", "one", "two"])

        state.reconcile(
            authoritativePaneIDs: ["one", "two", "three"],
            authoritativeRevision: 20
        )
        #expect(state.complete(requestID: request.id, succeeded: true) == .awaitingAuthority)
        #expect(state.visiblePaneIDs == ["three", "one", "two"])
        #expect(state.isMutationPending)

        state.reconcile(
            authoritativePaneIDs: ["one", "two", "three"],
            authoritativeRevision: 21
        )
        #expect(state.visiblePaneIDs == ["one", "two", "three"])
        #expect(!state.isMutationPending)
    }

    @Test func authoritativeRevisionCanArriveBeforeTheRequestCompletion() throws {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["left", "right"],
            authoritativeRevision: 30
        )

        let pendingRequest = state.beginMove(from: 0, to: 1)
        let request = try #require(pendingRequest)
        state.reconcile(
            authoritativePaneIDs: ["left", "right"],
            authoritativeRevision: 31
        )

        #expect(state.isMutationPending)
        #expect(state.complete(requestID: request.id, succeeded: true) == .awaitingAuthority)
        #expect(state.visiblePaneIDs == ["left", "right"])
        #expect(!state.isMutationPending)
    }

    @Test func staleCompletionCannotOverwriteANewerMove() throws {
        var state = PaneMapReorderState(
            authoritativePaneIDs: ["a", "b", "c"],
            authoritativeRevision: 40
        )

        let firstPendingRequest = state.beginMove(from: 0, to: 1)
        let first = try #require(firstPendingRequest)
        #expect(state.complete(requestID: first.id, succeeded: false) == .rolledBack)

        let secondPendingRequest = state.beginMove(from: 2, to: 0)
        let second = try #require(secondPendingRequest)
        #expect(state.complete(requestID: first.id, succeeded: true) == .ignored)
        #expect(state.visiblePaneIDs == second.orderedPaneIDs)
        #expect(state.isMutationPending)
    }
}
