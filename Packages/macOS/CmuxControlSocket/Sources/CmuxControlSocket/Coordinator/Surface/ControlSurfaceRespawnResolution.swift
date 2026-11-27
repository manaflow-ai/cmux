public import Foundation

/// The outcome of `surface.respawn`, preserving the legacy body's distinct
/// (localized) failures and the respawned identity.
///
/// The error *messages* are localized, so this enum carries only the discriminator
/// plus each case's `data` ids; the coordinator selects the matching message from
/// ``ControlSurfaceRespawnStrings`` (resolved in the app bundle) and shapes the
/// payload, keeping the wire output byte-identical including translations.
public enum ControlSurfaceRespawnResolution: Sendable, Equatable {
    /// The explicit-`surface_id` branch could not resolve the surface (legacy
    /// `not_found` / `surfaceNotFoundForID`). Carries the requested id for the
    /// `data` (or `nil` when the id itself did not parse).
    case surfaceNotFoundForID(UUID?)
    /// No fallback TabManager for the focused-surface branch (legacy `unavailable`
    /// / `tabManagerUnavailable`).
    case tabManagerUnavailable
    /// No workspace resolved on the focused branch (legacy `not_found` /
    /// `workspaceNotFound`).
    case workspaceNotFound
    /// No focused surface on the focused branch (legacy `not_found` /
    /// `noFocusedSurface`).
    case noFocusedSurface
    /// The resolved surface is not a terminal (legacy `invalid_params` /
    /// `surfaceNotTerminal`, `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotTerminal(UUID)
    /// The respawn call failed (legacy `internal_error` / `failed`,
    /// `data: {"surface_id": …}`). Carries the surface id.
    case respawnFailed(UUID)
    /// The surface respawned. Carries the echoed identity and the resulting panel
    /// type.
    case respawned(
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID,
        typeRawValue: String
    )
}
