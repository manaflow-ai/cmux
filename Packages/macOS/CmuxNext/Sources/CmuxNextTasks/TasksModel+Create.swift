import Foundation

/// New Task: the pane's title field sends `task.create` through the intent
/// log with a client-chosen `task_` id, so a resend after a reconnect
/// replays the same task instead of making a second one.
extension TasksModel {
    /// Creates a task titled `title` (trimmed) in the owner's default
    /// status, selects it, and returns its id. Nil for an empty title or
    /// while the owner is unreachable.
    @discardableResult
    public func createTask(title: String, newID: () -> String = TasksModel.mintTaskID) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = newID()
        guard send(.create(id: id, title: trimmed, status: nil)) else { return nil }
        selection = id
        return id
    }

    /// Asks the pane to focus its New Task field (user-initiated New Task only).
    public func focusNewTask() {
        newTaskFocusRequest += 1
    }

    /// A client-chosen task id the owner accepts (`task_[0-9a-z_-]{1,64}`).
    public static func mintTaskID() -> String {
        "task_" + UUID().uuidString.lowercased()
    }
}
