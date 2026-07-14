public import Foundation

/// The app-side resolution of `workspace.todo.list`.
public enum ControlWorkspaceTodoChecklistResolution: Sendable {
    /// No TabManager resolved from the routing selectors.
    case tabManagerUnavailable
    /// The workspace was not found (or no workspace is selected).
    case notFound
    /// The checklist snapshot, with the owning window.
    case resolved(windowID: UUID?, checklist: ControlWorkspaceTodoChecklistSnapshot)
}
