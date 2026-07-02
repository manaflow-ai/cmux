public import Foundation

/// The workspace-todo slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella): todo status (inference + manual
/// override) and the persisted checklist.
///
/// The app target conforms by resolving the target workspace — the explicit
/// `workspaceID` when given (workspace-owner-first, like
/// `workspace.prompt_submit`), else the routed window's selected workspace —
/// and reading/mutating its `WorkspaceTodoState` through the shared
/// `Workspace+Todos` entry points. Status/state/origin values cross the seam
/// as raw wire strings and come back in Sendable snapshots; no app types
/// cross.
@MainActor
public protocol ControlWorkspaceTodoContext: AnyObject {
    /// Reads the todo status for `workspace.status.get` (reconciling an
    /// expired override first).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    /// - Returns: The status resolution.
    func controlWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution

    /// Applies a manual status override (or clears it) for
    /// `workspace.status.set`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    ///   - statusRaw: The status lane raw value to pin, or `nil` for `auto`
    ///     (clear the override).
    /// - Returns: The status resolution after the mutation.
    func controlSetWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        statusRaw: String?
    ) -> ControlWorkspaceTodoStatusResolution

    /// Reads the checklist for `workspace.todo.list`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    /// - Returns: The checklist resolution.
    func controlWorkspaceTodoList(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoChecklistResolution

    /// Appends a checklist item for `workspace.todo.add`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    ///   - text: The raw item text (the seam trims/validates it).
    ///   - stateRaw: The initial state raw value, or `nil` for pending.
    ///   - originRaw: The origin raw value, or `nil` for user.
    /// - Returns: The mutation resolution.
    func controlWorkspaceTodoAdd(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        text: String,
        stateRaw: String?,
        originRaw: String?
    ) -> ControlWorkspaceTodoMutationResolution

    /// Sets one checklist item's state for `workspace.todo.set_state`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    ///   - itemID: The item's id, if the caller addressed it by id.
    ///   - itemIndex: The item's 0-based index, if addressed by index.
    ///   - stateRaw: The new state raw value.
    /// - Returns: The mutation resolution.
    func controlWorkspaceTodoSetState(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        stateRaw: String
    ) -> ControlWorkspaceTodoMutationResolution

    /// Removes one checklist item for `workspace.todo.remove`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    ///   - itemID: The item's id, if the caller addressed it by id.
    ///   - itemIndex: The item's 0-based index, if addressed by index.
    /// - Returns: The mutation resolution.
    func controlWorkspaceTodoRemove(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?
    ) -> ControlWorkspaceTodoMutationResolution

    /// Removes every checklist item for `workspace.todo.clear`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    /// - Returns: The mutation resolution.
    func controlWorkspaceTodoClear(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoMutationResolution

    /// Atomically replaces the checklist for `workspace.todo.set`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    ///   - items: The full desired checklist, in order.
    /// - Returns: The set resolution.
    func controlWorkspaceTodoSet(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        items: [ControlWorkspaceTodoSetItemParam]
    ) -> ControlWorkspaceTodoSetResolution

    /// Opens (or focuses) the workspace's todo pane for
    /// `workspace.todo.open`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The explicit target workspace, or `nil` for the
    ///     resolved window's selected workspace.
    ///   - requestedFocus: Whether the caller asked the pane to take focus.
    /// - Returns: The open resolution.
    func controlWorkspaceTodoOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        requestedFocus: Bool
    ) -> ControlWorkspaceTodoOpenResolution
}
