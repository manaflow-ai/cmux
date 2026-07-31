import Foundation

/// App-owned per-workspace FIFO for complete agent prompt transactions.
///
/// Queue admission is main-actor isolated so concurrent socket workers acquire
/// one deterministic app-arrival order before any unstructured task can run.
/// Explicit queues remain necessary because `drain` awaits delivery and the
/// main actor is reentrant across that suspension. Different workspaces have
/// independent drains.
@MainActor
final class AgentPromptSubmissionService {
    typealias Delivery =
        @MainActor @Sendable () async -> AgentPromptSubmissionResult
    typealias Completion = @Sendable (AgentPromptSubmissionResult) -> Void
    private typealias PendingSubmission = (
        delivery: Delivery,
        completion: Completion
    )

    private var pendingByWorkspace: [UUID: [PendingSubmission]] = [:]
    private var drainingWorkspaces: Set<UUID> = []

    /// Enqueues one complete delivery in the workspace's app-arrival order.
    ///
    /// - Parameters:
    ///   - workspaceID: The FIFO ownership key.
    ///   - delivery: The indivisible terminal transaction to execute.
    ///   - completion: Receives the transaction's definitive result.
    func enqueue(
        workspaceID: UUID,
        delivery: @escaping Delivery,
        completion: @escaping Completion
    ) {
        pendingByWorkspace[workspaceID, default: []].append(
            (delivery: delivery, completion: completion)
        )
        guard drainingWorkspaces.insert(workspaceID).inserted else { return }
        Task {
            await self.drain(workspaceID: workspaceID)
        }
    }

    private func drain(workspaceID: UUID) async {
        while let pending = dequeue(workspaceID: workspaceID) {
            let result = await pending.delivery()
            pending.completion(result)
        }
        drainingWorkspaces.remove(workspaceID)
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
