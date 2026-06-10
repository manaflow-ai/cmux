public import Foundation

/// The outcome of `surface.create`, preserving the legacy body's distinct failures
/// and the created identity.
///
/// The coordinator signals `unavailable`; the app maps the type token, validates
/// the agent-session provider/renderer (when the type is `agent-session`), runs the
/// browser-disabled path, resolves the workspace and pane, creates the surface, and
/// returns this resolution.
public enum ControlSurfaceCreateResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// The agent-session `provider` token was invalid (legacy `invalid_params` /
    /// "Invalid provider (codex|claude|opencode)", `data: {"provider": …}`).
    case invalidProvider(rawValue: String)
    /// The agent-session `renderer` token was invalid (legacy `invalid_params` /
    /// "Invalid renderer (react|solid)", `data: {"renderer": …}`).
    case invalidRenderer(rawValue: String)
    /// The browser was disabled; carries the shared external-open outcome.
    case browserDisabled(ControlSurfaceBrowserDisabledOutcome)
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// The requested/focused pane did not resolve (legacy `not_found` / "Pane not
    /// found").
    case paneNotFound
    /// The surface creation failed (legacy `internal_error` / "Failed to create
    /// surface").
    case createFailed
    /// The surface was created. Carries the echoed identity and the panel type.
    case created(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID,
        surfaceID: UUID,
        typeRawValue: String
    )
}
