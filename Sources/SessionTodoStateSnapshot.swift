import Foundation

/// A bounded value captured from one workspace, applied by the session writer.
struct SessionTodoStateSnapshot: Sendable {
    let workspaceID: UUID
    let statusOverride: String?
    let inferredAtOverride: String?
    let statusHidden: Bool?
    let checklist: [SessionChecklistItemSnapshot]?

    func apply(to snapshot: inout AppSessionSnapshot) -> Bool {
        for windowIndex in snapshot.windows.indices {
            guard let workspaceIndex = snapshot.windows[windowIndex].tabManager.workspaces.firstIndex(where: {
                $0.workspaceId == workspaceID
            }) else { continue }
            snapshot.windows[windowIndex].tabManager.workspaces[workspaceIndex].taskStatusOverride = statusOverride
            snapshot.windows[windowIndex].tabManager.workspaces[workspaceIndex].taskStatusInferredAtOverride = inferredAtOverride
            snapshot.windows[windowIndex].tabManager.workspaces[workspaceIndex].taskStatusHidden = statusHidden
            snapshot.windows[windowIndex].tabManager.workspaces[workspaceIndex].checklist = checklist
            return true
        }
        return false
    }
}

extension SessionTodoStateSnapshot {
    @MainActor
    init(workspace: Workspace) {
        workspaceID = workspace.id
        statusOverride = workspace.todoState.statusOverride?.status.rawValue
        inferredAtOverride = workspace.todoState.statusOverride?.inferredAtOverride.rawValue
        statusHidden = workspace.todoState.statusHidden ? true : nil
        checklist = workspace.todoState.checklist.isEmpty
            ? nil : workspace.todoState.checklist.map(SessionChecklistItemSnapshot.init(item:))
    }
}
