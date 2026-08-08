public import Foundation

/// Folds one agent's reported task list into a workspace checklist, producing
/// the replacement list for `replaceChecklist(with:)`.
///
/// Ownership is read from the rows themselves: a row belongs to the reporting
/// agent when its persisted ``WorkspaceChecklistItem/agentTaskRef`` names that
/// workstream. Because that reference is persisted with the checklist, it
/// survives an app restart, a dropped event, or eviction of any in-memory
/// bookkeeping — a resumed session can still retire and update exactly its own
/// rows.
///
/// Rows authored by the user, and rows owned by *other* agents sharing the
/// workspace, keep their identity, text, state, and relative order, so two
/// agents in one workspace do not erase each other's checklists. Rows the
/// reporting agent owns but no longer reports are retired, which is what makes
/// an all-tasks-deleted report meaningful.
///
/// The reporting agent's rows are re-emitted as a block after the rows it does
/// not own, in the order the agent reports them, so the checklist follows the
/// agent's own plan ordering rather than the order its rows happened to land.
///
/// - Parameters:
///   - existing: The workspace's current checklist, in display order.
///   - agentTasks: The reporting agent's full current task list. May be empty,
///     which retires every row that agent owns without touching anything else.
///   - workstreamId: The reporting workstream (agent session) id.
/// - Returns: The full desired checklist, or `nil` when applying the report
///   would not change anything.
public func workspaceAgentChecklistReplacement(
    existing: [WorkspaceChecklistItem],
    agentTasks: [WorkspaceAgentChecklistTask],
    workstreamId: String
) -> [WorkspaceChecklistReplacementItem]? {
    // Normalize up front so the "already matches" comparison below sees the
    // same text `replaceChecklist` would store, and blank subjects drop out.
    let normalizedTasks = agentTasks.compactMap { task -> WorkspaceAgentChecklistTask? in
        guard let text = WorkspaceChecklistItem.normalizedText(task.text) else { return nil }
        return WorkspaceAgentChecklistTask(id: task.id, ref: task.ref, text: text, state: task.state)
    }

    // Rows to keep verbatim: everything the reporting agent does not own. Its
    // own rows are dropped here and the ones it still reports are re-emitted
    // below, so unreported ones retire.
    let retained = existing
        .filter { $0.agentTaskRef?.workstreamId != workstreamId }
        .map { item in
            WorkspaceChecklistReplacementItem(
                id: item.id,
                text: item.text,
                state: item.state,
                origin: item.origin,
                agentTaskRef: item.agentTaskRef
            )
        }

    // The replace is rejected wholesale past the cap. Trim only the incoming
    // agent portion so a long agent plan can never delete rows the user or
    // another agent authored.
    let agentBudget = max(0, WorkspaceChecklistItem.maxChecklistItems - retained.count)
    let admitted = normalizedTasks.suffix(agentBudget)

    var items = retained
    items.reserveCapacity(retained.count + admitted.count)
    for task in admitted {
        items.append(WorkspaceChecklistReplacementItem(
            id: task.id,
            text: task.text,
            state: task.state,
            origin: .agent,
            agentTaskRef: task.ref
        ))
    }

    guard !checklistMatches(existing, items) else { return nil }
    return items
}

private func checklistMatches(
    _ existing: [WorkspaceChecklistItem],
    _ items: [WorkspaceChecklistReplacementItem]
) -> Bool {
    guard existing.count == items.count else { return false }
    for (current, incoming) in zip(existing, items) {
        guard current.id == incoming.id,
              current.text == incoming.text,
              current.state == incoming.state,
              current.agentTaskRef == incoming.agentTaskRef else { return false }
    }
    return true
}
