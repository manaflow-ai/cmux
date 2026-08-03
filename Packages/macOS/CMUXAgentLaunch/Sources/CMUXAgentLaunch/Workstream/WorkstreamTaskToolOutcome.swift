import Foundation

/// The outcome of feeding one task-tool call to ``WorkstreamTaskToolTodos``.
///
/// Distinguishing ``ignored`` from an empty ``list(_:)`` matters: deleting the
/// agent's last task is a real empty-list transition that must retire its
/// checklist rows, while an unparseable payload must fall through to ordinary
/// tool telemetry and leave the checklist alone.
enum WorkstreamTaskToolOutcome: Equatable {
    /// The payload carried nothing usable; the caller should fall back to
    /// plain tool-use telemetry.
    case ignored
    /// The workstream's task list after applying the call.
    case list([WorkstreamTaskTodo])
}
