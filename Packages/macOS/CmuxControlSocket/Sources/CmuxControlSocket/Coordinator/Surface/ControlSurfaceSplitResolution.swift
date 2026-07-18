public import Foundation

/// The outcome of `surface.split`, preserving the legacy body's distinct failures
/// and the created identity.
///
/// The coordinator validates `direction` and the divider (returning
/// `invalid_params` itself) and signals `unavailable`; the app maps the type token,
/// rejects `agent-session`, runs the browser-disabled path, resolves the workspace
/// and target surface, creates the split, and returns this resolution.
public enum ControlSurfaceSplitResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// The direction token did not parse (legacy `invalid_params` /
    /// "Missing or invalid direction (left|right|up|down)"). The coordinator
    /// pre-validates the same token set, so this is a drift-safety net.
    case invalidDirection
    /// The type token resolved to `agent-session` (legacy `invalid_params` /
    /// "agent-session is only supported by surface.create", `data: {"type": …}`).
    case agentSessionRejected(typeRawValue: String)
    /// The browser was disabled; carries the shared external-open outcome.
    case browserDisabled(ControlSurfaceBrowserDisabledOutcome)
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// The requested `surface_id` did not exist (legacy `not_found` / "Surface not
    /// found", `data: {"surface_id": …}`).
    case requestedSurfaceNotFound(UUID)
    /// No focused surface to split (legacy `not_found` / "No focused surface").
    case noFocusedSurface
    /// The split creation failed (legacy `internal_error` / "Failed to create
    /// split").
    case createFailed
    /// The request carried options the routed remote tmux `split-window`
    /// cannot honor; rejected BEFORE the remote session was mutated (an error
    /// after the mutation invites retries that duplicate remote panes).
    case mirrorUnsupportedOptions([String])
    /// The split was routed to the remote tmux mirror backing the workspace.
    /// No local surface exists yet — it arrives asynchronously via the
    /// mirror's `%layout-change` handling, so there is no surface id to echo.
    case routedToRemote(windowID: UUID?, workspaceID: UUID, typeRawValue: String)
    /// The split was created. Carries the echoed identity and the resulting panel
    /// type (which may be `nil` if the new panel could not be re-read).
    case created(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID?,
        surfaceID: UUID,
        typeRawValue: String?
    )
}
