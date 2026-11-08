import Foundation

/// Holds one mount-authoritative workspace retirement until its focus pass finishes.
struct WorkspaceHandoffRetirementGate {
    /// The source workspace and selection generation associated with a handoff.
    struct Request: Equatable {
        let workspaceID: UUID
        let reason: String
        let selectionGeneration: UInt64
    }

    private(set) var pendingRequest: Request?
    private var currentSelectionGeneration: UInt64?
    private var completedFocusPassGeneration: UInt64?

    mutating func reset(forSelectionGeneration generation: UInt64) {
        currentSelectionGeneration = generation
        completedFocusPassGeneration = nil
        pendingRequest = nil
    }

    @discardableResult
    mutating func request(
        workspaceID: UUID,
        reason: String,
        selectionGeneration: UInt64
    ) -> Request? {
        guard currentSelectionGeneration == selectionGeneration else { return nil }
        pendingRequest = Request(
            workspaceID: workspaceID,
            reason: reason,
            selectionGeneration: selectionGeneration
        )
        return takeIfReady()
    }

    @discardableResult
    mutating func markFocusPassCompleted(generation: UInt64) -> Request? {
        guard currentSelectionGeneration == generation else { return nil }
        completedFocusPassGeneration = generation
        return takeIfReady()
    }

    mutating func cancel() {
        pendingRequest = nil
    }

    func isTracking(selectionGeneration: UInt64) -> Bool {
        currentSelectionGeneration == selectionGeneration
    }

    private mutating func takeIfReady() -> Request? {
        guard let pendingRequest,
              completedFocusPassGeneration == pendingRequest.selectionGeneration else {
            return nil
        }
        self.pendingRequest = nil
        return pendingRequest
    }
}
