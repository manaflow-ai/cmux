import Foundation

/// Optimistic pane-map ordering reconciled against the Mac's authoritative layout.
struct PaneMapReorderState: Equatable {
    struct Request: Equatable, Sendable {
        let id: UUID
        let orderedPaneIDs: [String]
        /// The authoritative layout revision this drag was computed against.
        /// Sent to the Mac as the reorder's precondition so a stale drag fails
        /// closed as a conflict instead of permuting the wrong pane contents.
        let baseLayoutRevision: Int
    }

    enum Completion: Equatable {
        case ignored
        case rolledBack
        case awaitingAuthority
    }

    private(set) var visiblePaneIDs: [String]
    private(set) var authoritativePaneIDs: [String]
    private(set) var authoritativeRevision: Int
    private(set) var pendingRequest: Request?
    private var receivedAuthorityWhilePending = false
    private var pendingRequestWasAccepted = false

    var isMutationPending: Bool {
        pendingRequest != nil
    }

    init(authoritativePaneIDs: [String], authoritativeRevision: Int) {
        self.visiblePaneIDs = authoritativePaneIDs
        self.authoritativePaneIDs = authoritativePaneIDs
        self.authoritativeRevision = authoritativeRevision
    }

    mutating func beginMove(from sourceIndex: Int, to destinationIndex: Int) -> Request? {
        guard pendingRequest == nil,
              visiblePaneIDs.indices.contains(sourceIndex),
              visiblePaneIDs.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else {
            return nil
        }
        let movedPaneID = visiblePaneIDs.remove(at: sourceIndex)
        visiblePaneIDs.insert(movedPaneID, at: destinationIndex)
        let request = Request(
            id: UUID(),
            orderedPaneIDs: visiblePaneIDs,
            baseLayoutRevision: authoritativeRevision
        )
        pendingRequest = request
        receivedAuthorityWhilePending = false
        pendingRequestWasAccepted = false
        return request
    }

    mutating func reconcile(
        authoritativePaneIDs: [String],
        authoritativeRevision: Int
    ) {
        // Revisions are monotonic per Mac process, so a delayed older
        // workspace-list response must never roll the map back after newer
        // authority applied. (A Mac restart resets the counter, but that also
        // drops the connection and rebuilds this state with a fresh baseline.)
        guard authoritativeRevision >= self.authoritativeRevision else { return }
        let receivedNewAuthority = authoritativeRevision > self.authoritativeRevision
        self.authoritativePaneIDs = authoritativePaneIDs
        self.authoritativeRevision = authoritativeRevision
        guard pendingRequest != nil else {
            visiblePaneIDs = authoritativePaneIDs
            return
        }
        guard receivedNewAuthority else { return }
        receivedAuthorityWhilePending = true
        if pendingRequestWasAccepted {
            finishSuccessfulMutationAfterAuthoritativeRefresh()
        }
    }

    mutating func complete(requestID: UUID, succeeded: Bool) -> Completion {
        guard pendingRequest?.id == requestID else { return .ignored }
        if !succeeded {
            pendingRequest = nil
            receivedAuthorityWhilePending = false
            pendingRequestWasAccepted = false
            visiblePaneIDs = authoritativePaneIDs
            return .rolledBack
        }
        pendingRequestWasAccepted = true
        guard receivedAuthorityWhilePending else {
            return .awaitingAuthority
        }
        finishSuccessfulMutationAfterAuthoritativeRefresh()
        return .awaitingAuthority
    }

    mutating func finishSuccessfulMutationAfterAuthoritativeRefresh() {
        guard pendingRequest != nil else { return }
        pendingRequest = nil
        receivedAuthorityWhilePending = false
        pendingRequestWasAccepted = false
        visiblePaneIDs = authoritativePaneIDs
    }
}
