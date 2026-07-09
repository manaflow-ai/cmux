public import Foundation

/// The app-side resolution of `workspace.todo.open`.
public enum ControlWorkspaceTodoOpenResolution: Sendable, Equatable {
    /// No TabManager resolved from the routing selectors.
    case tabManagerUnavailable
    /// The workspace was not found (or no workspace is selected).
    case notFound
    /// The pane could not be created or focused (no focused pane, or
    /// surface creation failed).
    case openFailed
    /// The todo pane is open (created, or an existing one focused).
    ///
    /// - Parameters:
    ///   - windowID: The routed window, if it resolved.
    ///   - workspaceID: The owning workspace.
    ///   - paneID: The pane hosting the todo panel, if it resolved.
    ///   - surfaceID: The todo panel.
    case opened(windowID: UUID?, workspaceID: UUID, paneID: UUID?, surfaceID: UUID)
}
