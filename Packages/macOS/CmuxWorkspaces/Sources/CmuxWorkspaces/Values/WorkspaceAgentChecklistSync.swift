import Foundation

/// Produces one authoritative checklist replacement for an agent report.
/// User rows and rows owned by other workstreams remain untouched; rows owned
/// by this workstream but absent from the report are retired.
public struct WorkspaceAgentChecklistSync: Sendable {
    /// Creates a stateless sync service.
    public init() {}

    /// Computes the full replacement for one workstream's report.
    public func replacement(
        existing: [WorkspaceChecklistItem],
        agentTasks: [WorkspaceAgentChecklistTask],
        workstreamId: String
    ) -> [WorkspaceChecklistReplacementItem]? {
        let normalized = agentTasks.compactMap { task -> WorkspaceAgentChecklistTask? in
            guard let text = WorkspaceChecklistItem.normalizedText(task.text) else { return nil }
            return WorkspaceAgentChecklistTask(
                id: task.id,
                ref: task.ref,
                text: text,
                state: task.state,
                lastActivityAt: task.lastActivityAt,
                agentName: task.agentName
            )
        }
        let retained = existing
            .filter { $0.agentTaskRef?.workstreamId != workstreamId }
            .map { item in
                WorkspaceChecklistReplacementItem(
                    id: item.id,
                    text: item.text,
                    state: item.state,
                    origin: item.origin,
                    agentTaskRef: item.agentTaskRef,
                    dispatchTarget: item.dispatchTarget,
                    boundWorkspaceID: item.boundWorkspaceID,
                    boundAgent: item.boundAgent,
                    lastActivityAt: item.lastActivityAt
                )
            }
        let budget = max(0, WorkspaceChecklistItem.maxChecklistItems - retained.count)
        let admitted = normalized.suffix(budget)
        var result = retained
        result.reserveCapacity(retained.count + admitted.count)
        for task in admitted {
            result.append(WorkspaceChecklistReplacementItem(
                id: task.id,
                text: task.text,
                state: task.state,
                origin: .agent,
                agentTaskRef: task.ref,
                dispatchTarget: nil,
                boundWorkspaceID: nil,
                boundAgent: task.agentName,
                lastActivityAt: task.lastActivityAt
            ))
        }
        guard !matches(existing, result) else { return nil }
        return result
    }

    private func matches(
        _ existing: [WorkspaceChecklistItem],
        _ incoming: [WorkspaceChecklistReplacementItem]
    ) -> Bool {
        guard existing.count == incoming.count else { return false }
        for (current, next) in zip(existing, incoming) {
            guard current.id == next.id,
                  current.text == next.text,
                  current.state == next.state,
                  current.origin == next.origin,
                  current.agentTaskRef == next.agentTaskRef,
                  current.dispatchTarget == next.dispatchTarget,
                  current.boundWorkspaceID == next.boundWorkspaceID,
                  current.boundAgent == next.boundAgent,
                  current.lastActivityAt == next.lastActivityAt else { return false }
        }
        return true
    }
}
