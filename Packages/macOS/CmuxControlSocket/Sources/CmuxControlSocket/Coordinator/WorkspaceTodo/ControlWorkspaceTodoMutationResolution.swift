public import Foundation

/// The app-side resolution of the checklist mutations (`workspace.todo.add`
/// / `.set_state` / `.remove` / `.clear`).
public enum ControlWorkspaceTodoMutationResolution: Sendable {
    /// No TabManager resolved from the routing selectors.
    case tabManagerUnavailable
    /// The workspace was not found (or no workspace is selected).
    case notFound
    /// No checklist item matched the given id/index.
    case itemNotFound
    /// `workspace.todo.add` text was empty after trimming.
    case emptyText
    /// The checklist is at its item cap.
    case checklistFull
    /// The `state` param was not a known state (the string is echoed back).
    case invalidState(String)
    /// The `origin` param was not a known origin (the string is echoed back).
    case invalidOrigin(String)
    /// The mutation succeeded: the touched item (`nil` for `clear`), the
    /// number of items removed (`clear` / `remove`), and the checklist after
    /// the mutation.
    case resolved(
        windowID: UUID?,
        item: ControlWorkspaceTodoChecklistSnapshot.Item?,
        removedCount: Int,
        checklist: ControlWorkspaceTodoChecklistSnapshot
    )
}
