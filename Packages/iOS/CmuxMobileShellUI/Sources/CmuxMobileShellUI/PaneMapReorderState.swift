import Foundation

/// Optimistic pane-map ordering reconciled against the Mac's authoritative layout.
struct PaneMapReorderState: Equatable {
    struct Request: Equatable, Sendable {
        let id: UUID
        let orderedPaneIDs: [String]
    }

    enum Completion: Equatable {
        case ignored
        case rolledBack
        case awaitingAuthority
    }

    private(set) var visiblePaneIDs: [String]
    private(set) var authoritativePaneIDs: [String]
    private(set) var pendingRequest: Request?
    private var receivedAuthorityWhilePending = false
    private var pendingRequestWasAccepted = false

    var isMutationPending: Bool {
        pendingRequest != nil
    }

    init(authoritativePaneIDs: [String]) {
        self.visiblePaneIDs = authoritativePaneIDs
        self.authoritativePaneIDs = authoritativePaneIDs
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
        let request = Request(id: UUID(), orderedPaneIDs: visiblePaneIDs)
        pendingRequest = request
        receivedAuthorityWhilePending = false
        pendingRequestWasAccepted = false
        return request
    }

    mutating func reconcile(authoritativePaneIDs: [String]) {
        self.authoritativePaneIDs = authoritativePaneIDs
        guard pendingRequest != nil else {
            visiblePaneIDs = authoritativePaneIDs
            return
        }
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
