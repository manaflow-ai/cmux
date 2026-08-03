public import Foundation

/// One agent-reported task, already mapped onto checklist vocabulary.
public struct WorkspaceAgentChecklistTask: Sendable, Equatable {
    /// The stable checklist identity derived from the agent's task id.
    public let id: UUID
    public let text: String
    public let state: WorkspaceChecklistItem.State

    public init(id: UUID, text: String, state: WorkspaceChecklistItem.State) {
        self.id = id
        self.text = text
        self.state = state
    }
}

/// Folds an agent's reported task list into a workspace checklist.
///
/// The agent owns only the rows it created: user rows are carried through
/// untouched (identity, text, state, position), and agent rows the agent no
/// longer reports are dropped. An empty report is *not* an instruction to
/// clear the checklist — Claude fires per-task tool calls, so an empty list
/// usually means "nothing parsed yet", and honoring it would wipe items the
/// user typed by hand. See https://github.com/manaflow-ai/cmux/issues/8960.
public enum WorkspaceAgentChecklistSync {
    /// Builds the replacement list for `replaceChecklist(with:)`.
    ///
    /// - Returns: The full desired checklist, or `nil` when there is nothing
    ///   to apply (empty report, or the result would not change anything).
    public static func replacementItems(
        existing: [WorkspaceChecklistItem],
        agentTasks: [WorkspaceAgentChecklistTask]
    ) -> [WorkspaceChecklistReplacementItem]? {
        // Normalize up front so the "already matches" comparison below sees
        // the same text `replaceChecklist` would store, and drop tasks whose
        // subject is blank.
        let normalizedTasks = agentTasks.compactMap { task -> WorkspaceAgentChecklistTask? in
            guard let text = WorkspaceChecklistItem.normalizedText(task.text) else { return nil }
            return WorkspaceAgentChecklistTask(id: task.id, text: text, state: task.state)
        }
        guard !normalizedTasks.isEmpty else { return nil }

        var items: [WorkspaceChecklistReplacementItem] = []
        items.reserveCapacity(existing.count + normalizedTasks.count)

        let agentIds = Set(normalizedTasks.map(\.id))
        for item in existing where item.origin == .user && !agentIds.contains(item.id) {
            items.append(WorkspaceChecklistReplacementItem(
                id: item.id,
                text: item.text,
                state: item.state,
                origin: .user
            ))
        }
        for task in normalizedTasks {
            items.append(WorkspaceChecklistReplacementItem(
                id: task.id,
                text: task.text,
                state: task.state,
                origin: .agent
            ))
        }
        // The replace is rejected wholesale past the cap, so trim to the last
        // N rows (the agent's tail) instead of dropping the sync entirely.
        if items.count > WorkspaceChecklistItem.maxChecklistItems {
            items = Array(items.suffix(WorkspaceChecklistItem.maxChecklistItems))
        }

        guard !matchesExisting(existing, items) else { return nil }
        return items
    }

    private static func matchesExisting(
        _ existing: [WorkspaceChecklistItem],
        _ items: [WorkspaceChecklistReplacementItem]
    ) -> Bool {
        guard existing.count == items.count else { return false }
        for (current, incoming) in zip(existing, items) {
            guard current.id == incoming.id,
                  current.text == incoming.text,
                  current.state == incoming.state else { return false }
        }
        return true
    }
}
