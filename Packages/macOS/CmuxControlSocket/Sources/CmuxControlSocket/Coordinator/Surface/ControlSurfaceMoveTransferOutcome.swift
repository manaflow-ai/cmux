internal import Foundation

/// The outcome of the cross-workspace transfer branch of `surface.move`,
/// preserving the legacy `v2SurfaceMove` detach/attach failure paths.
///
/// When the destination workspace differs from the source, the app detaches the
/// surface from the source workspace and attaches it onto the target (rolling
/// back to the source pane/index if the attach fails, then focusing the target
/// window/workspace when allowed). This names the two failure points and the
/// success the coordinator maps to the move payload.
public enum ControlSurfaceMoveTransferOutcome: Sendable, Equatable {
    /// `detachSurface` returned `nil` (legacy `internal_error` / "Failed to
    /// detach surface").
    case detachFailed
    /// `attachDetachedSurface` returned `nil`; the surface was rolled back to the
    /// source (legacy `internal_error` / "Failed to attach surface to
    /// destination").
    case attachFailed
    /// The surface was detached and attached onto the target successfully.
    case transferred
}
