public import Foundation

/// Outcome of a canvas-domain mutation, mapped by the coordinator onto the
/// wire error vocabulary (`unavailable`, `not_found`, `invalid_state`).
public enum ControlCanvasActionResolution: Sendable, Equatable {
    /// The action ran; `mode` is the workspace's layout mode afterwards.
    case ok(mode: String)
    /// A pane was created; carries the layout mode and the new surface's id.
    case created(mode: String, surfaceID: UUID)
    case tabManagerUnavailable
    case workspaceNotFound
    /// A canvas-only action was requested while the workspace is in splits.
    case notCanvasMode
    case paneNotFound(UUID)
    /// The action needed a target pane but no surface selector was given and
    /// the workspace has no focused panel.
    case noFocusedPane
}
