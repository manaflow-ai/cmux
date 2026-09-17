public import Foundation

/// The outcome of `pane.break`, preserving every distinct branch of the legacy
/// `v2PaneBreak` body and the new-workspace identity it echoes back.
///
/// The seam resolves the source workspace/pane/surface, detaches the surface
/// into a new workspace, and returns this resolution; the coordinator shapes the
/// final `JSONValue`.
public enum ControlPaneBreakResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A TabManager resolved but no workspace did (legacy `not_found` /
    /// "Workspace not found", `data: nil`).
    case workspaceNotFound
    /// There was no surface to break out (legacy `not_found` / "No source
    /// surface to break", `data: nil`).
    case noSourceSurface
    /// The resolved surface id did not exist in the workspace (legacy
    /// `not_found` / "Surface not found", `data: {"surface_id": …}`). Carries
    /// the surface id.
    case surfaceNotFound(UUID)
    /// Detaching the source surface failed (legacy `internal_error` / "Failed to
    /// detach source surface", `data: nil`).
    case detachFailed
    /// Creating the destination workspace failed (legacy `internal_error` /
    /// "Failed to create workspace for detached surface", `data: nil`). The
    /// legacy body rolled the detached surface back before returning.
    case createWorkspaceFailed
    /// The destination pane could not be resolved after the move (legacy
    /// `internal_error` / "Failed to resolve destination pane for detached
    /// surface", `data: {"workspace_id": …, "surface_id": …}`). Carries the new
    /// workspace id and the surface id.
    case destinationPaneUnresolved(workspaceID: UUID, surfaceID: UUID)
    /// The surface was broken out into a new workspace. Carries the echoed
    /// identity (window may be absent; workspace, pane, and surface present).
    case broken(windowID: UUID?, workspaceID: UUID, paneID: UUID, surfaceID: UUID)
}
