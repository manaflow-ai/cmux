import Foundation

/// App-owned per-workspace FIFO for complete agent prompt transactions.
///
/// Queue admission is main-actor isolated so concurrent socket workers acquire
/// one deterministic app-arrival order. Delivery is deliberately synchronous
/// and non-suspending: target resolution, the composer check, and the compound
/// terminal write all complete inside the socket's existing main-actor hop.
/// A same-workspace reentrant call is rejected before delivery.
@MainActor
final class AgentPromptSubmissionService {
    typealias Delivery =
        @MainActor @Sendable () -> AgentPromptSubmissionResult
    private typealias PendingSubmission = (id: UInt64, delivery: Delivery)

    private var pendingByWorkspace: [UUID: [PendingSubmission]] = [:]
    private var drainingWorkspaces: Set<UUID> = []
    private var nextSubmissionID: UInt64 = 0

    /// Enqueues and synchronously drains one complete delivery in app-arrival
    /// order.
    ///
    /// - Parameters:
    ///   - workspaceID: The FIFO ownership key.
    ///   - delivery: The indivisible terminal transaction to execute.
    /// - Returns: The transaction's definitive result.
    func submit(
        workspaceID: UUID,
        delivery: @escaping Delivery
    ) -> AgentPromptSubmissionResult {
        nextSubmissionID &+= 1
        if nextSubmissionID == 0 {
            nextSubmissionID = 1
        }
        let submissionID = nextSubmissionID
        pendingByWorkspace[workspaceID, default: []].append(
            (id: submissionID, delivery: delivery)
        )
        guard drainingWorkspaces.insert(workspaceID).inserted else {
            pendingByWorkspace[workspaceID]?.removeAll {
                $0.id == submissionID
            }
            if pendingByWorkspace[workspaceID]?.isEmpty == true {
                pendingByWorkspace.removeValue(forKey: workspaceID)
            }
            return .serviceUnavailable(workspaceID: workspaceID)
        }
        defer {
            drainingWorkspaces.remove(workspaceID)
        }
        var submissionResult: AgentPromptSubmissionResult?
        while let pending = dequeue(workspaceID: workspaceID) {
            let result = pending.delivery()
            if pending.id == submissionID {
                submissionResult = result
            }
        }
        return submissionResult ?? .serviceUnavailable(
            workspaceID: workspaceID
        )
    }

    private func dequeue(workspaceID: UUID) -> PendingSubmission? {
        guard var pending = pendingByWorkspace[workspaceID],
              !pending.isEmpty else {
            pendingByWorkspace.removeValue(forKey: workspaceID)
            return nil
        }
        let first = pending.removeFirst()
        if pending.isEmpty {
            pendingByWorkspace.removeValue(forKey: workspaceID)
        } else {
            pendingByWorkspace[workspaceID] = pending
        }
        return first
    }
}
