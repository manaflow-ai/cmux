internal import Foundation

/// The outcome of `workspace.move_to_window`, preserving the legacy body's three
/// distinct failures and the success echo. The coordinator has already
/// validated the `workspace_id` / `window_id` shapes.
public enum ControlWorkspaceMoveToWindowResolution: Sendable, Equatable {
    /// The source workspace was not found (legacy `not_found` / "Workspace not
    /// found", data carries only `workspace_id`). Covers both the missing
    /// source TabManager and the failed detach.
    case workspaceNotFound
    /// The destination window was not found (legacy `not_found` / "Window not
    /// found", data carries only `window_id`).
    case windowNotFound
    /// The workspace was moved (legacy success echoing workspace + window).
    case resolved
}
