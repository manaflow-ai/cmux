public import Foundation

/// The outcome of `surface.agent_chat.open`, mirroring the
/// `surface.trigger_flash` resolution shape.
///
/// The coordinator signals `unavailable`; the app resolves the workspace and
/// surface, hands the panel to the shared `AgentChatPresenter` path (the same
/// resolve-then-present flow the menu, command palette, keyboard shortcut, and
/// terminal context menu drive), and returns this resolution. Presentation is
/// asynchronous (transcript resolution globs the filesystem off-main), so the
/// success case acknowledges the request rather than the opened pane.
public enum ControlSurfaceAgentChatOpenResolution: Sendable, Equatable {
    /// No TabManager resolved (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (`not_found` / "Workspace not found").
    case workspaceNotFound
    /// No surface resolved and none focused (`not_found` / "No focused
    /// surface").
    case noFocusedSurface
    /// The surface id did not exist (`not_found` / "Surface not found",
    /// `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotFound(UUID)
    /// The shared presenter accepted the request. Carries the echoed identity.
    case requested(windowID: UUID?, workspaceID: UUID, surfaceID: UUID)
}
