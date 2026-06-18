public import Foundation

/// The outcome of `surface.read_text`, preserving the legacy body's distinct
/// failures and the read text.
///
/// The coordinator validates `lines` (`> 0`) itself; the app resolves the surface,
/// reads the Ghostty text, runs the (app-side) payload assembly, and returns this.
/// The `internalError` message is the app-side `TerminalTextPayloadError.message`
/// (or the generic "Failed to read terminal text"), carried through verbatim.
public enum ControlSurfaceReadTextResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// A `surface_id` param was present but did not parse (legacy `not_found` /
    /// "Surface not found for the given surface_id").
    case surfaceNotFoundForID
    /// No surface resolved and none focused (legacy `not_found` / "No focused
    /// surface").
    case noFocusedSurface
    /// The resolved surface is not a terminal (legacy `invalid_params` / "Surface
    /// is not a terminal", `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotTerminal(UUID)
    /// The read failed (legacy `internal_error`). Carries the app-side message.
    case internalError(message: String)
    /// The text was read. Carries the decoded text, its base64, and the identity.
    case read(
        text: String,
        base64: String,
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID
    )
}
