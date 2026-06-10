public import Foundation

/// The outcome of `workspace.create`, preserving the legacy body's failure modes
/// and the resolved window/workspace/surface the success echoes back.
public enum ControlWorkspaceCreateResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A param was malformed (legacy `invalid_params`). Carries the exact
    /// message the app produced (`"cwd must be a string"`, `"layout must be a
    /// valid JSON object"`, or `"Invalid layout: …"`).
    case invalidParams(message: String)
    /// Workspace creation failed (legacy `internal_error` / "Failed to create
    /// workspace").
    case creationFailed
    /// The workspace was created. Carries the owning window id (may be absent),
    /// the new workspace id, and the initial surface id (may be absent).
    case resolved(
        windowID: UUID?,
        workspaceID: UUID,
        initialSurfaceID: UUID?
    )
}
