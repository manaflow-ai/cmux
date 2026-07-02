import CmuxWorkspaces
import Foundation

/// One persisted checklist item. Raw `state` / `origin` strings (not the
/// package enums) so a manifest written by a future build with new cases
/// still decodes here; unknown values degrade to pending/user on restore.
struct SessionChecklistItemSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var text: String
    var state: String
    var origin: String
}

extension SessionChecklistItemSnapshot {
    /// Captures a live checklist item.
    init(item: WorkspaceChecklistItem) {
        self.init(
            id: item.id,
            text: item.text,
            state: item.state.rawValue,
            origin: item.origin.rawValue
        )
    }

    /// The live item this snapshot restores to, or `nil` when the persisted
    /// text is empty after normalization. Unknown state/origin raw values
    /// degrade to `.pending` / `.user` instead of dropping the item.
    var checklistItem: WorkspaceChecklistItem? {
        guard let normalizedText = WorkspaceChecklistItem.normalizedText(text) else { return nil }
        return WorkspaceChecklistItem(
            id: id,
            text: normalizedText,
            state: WorkspaceChecklistItem.State(rawValue: state) ?? .pending,
            origin: WorkspaceChecklistItem.Origin(rawValue: origin) ?? .user
        )
    }
}

extension SessionWorkspaceSnapshot {
    /// Captures the live todo state into the snapshot's persisted fields.
    @MainActor
    mutating func captureTodoState(from workspace: Workspace) {
        let override = workspace.todoState.statusOverride
        taskStatusOverride = override?.status.rawValue
        taskStatusInferredAtOverride = override?.inferredAtOverride.rawValue
        let items = workspace.todoState.checklist
        checklist = items.isEmpty ? nil : items.map(SessionChecklistItemSnapshot.init(item:))
    }

    /// The decoded status override, or `nil` when absent or when either raw
    /// value is unknown (a partial or unparseable override is dropped whole:
    /// restoring a guessed `inferredAtOverride` would defeat anti-rot expiry).
    var restoredTaskStatusOverride: WorkspaceTaskStatusOverride? {
        guard let statusRaw = taskStatusOverride,
              let inferredRaw = taskStatusInferredAtOverride,
              let status = WorkspaceTaskStatus(rawValue: statusRaw),
              let inferredAtOverride = WorkspaceTaskStatus(rawValue: inferredRaw) else {
            return nil
        }
        return WorkspaceTaskStatusOverride(status: status, inferredAtOverride: inferredAtOverride)
    }

    /// The decoded checklist (empty for pre-feature manifests), re-applying
    /// the item cap in case the manifest was written by a build with a
    /// larger cap or edited externally.
    var restoredChecklist: [WorkspaceChecklistItem] {
        (checklist ?? [])
            .compactMap { $0.checklistItem }
            .prefix(WorkspaceChecklistItem.maxChecklistItems)
            .map { $0 }
    }
}
