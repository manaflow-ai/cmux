public import Foundation

/// The outcome of `surface.send_text` / `surface.send_key`, preserving the legacy
/// bodies' distinct failures and the echoed identity.
///
/// The two send methods share this resolution; `unknownKey` is produced only by
/// `send_key`. The terminal-input error *messages* are localized, so the
/// `inputQueueFull` / `surfaceUnavailable` / `processExited` cases carry only the
/// discriminator and the surface id; the coordinator selects the matching message
/// from ``ControlSurfaceInputStrings`` (resolved in the app bundle).
public enum ControlSurfaceSendResolution: Sendable, Equatable {
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
    /// `send_key` received an unrecognized key (legacy `invalid_params` / "Unknown
    /// key", `data: {"key": …}`).
    case unknownKey
    /// The terminal input queue is full (legacy `input_queue_full`,
    /// `data: {"surface_id": …}`). Carries the surface id.
    case inputQueueFull(UUID)
    /// The surface is unavailable (legacy `surface_unavailable`,
    /// `data: {"surface_id": …}`). Carries the surface id.
    case surfaceUnavailable(UUID)
    /// The process has exited (legacy `process_exited`,
    /// `data: {"surface_id": …}`). Carries the surface id.
    case processExited(UUID)
    /// The input was sent. Carries the echoed identity and whether it was queued.
    case sent(windowID: UUID?, workspaceID: UUID, surfaceID: UUID, queued: Bool)
}
