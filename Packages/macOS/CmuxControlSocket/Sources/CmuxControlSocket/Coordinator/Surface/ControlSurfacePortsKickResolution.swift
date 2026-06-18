public import Foundation

/// The outcome of `surface.ports_kick`, preserving the legacy body's distinct
/// failures and the kicked identity.
///
/// The coordinator validates the params (workspace required, surface-if-present
/// must parse, reason must parse) and mints refs; every case echoes the workspace
/// id plus the requested-or-resolved surface id and the reason. The app kicks the
/// port scanner (locally or against the remote workspace) and returns this.
public enum ControlSurfacePortsKickResolution: Sendable, Equatable {
    /// The workspace did not resolve (legacy `not_found` / "Workspace not found",
    /// `data` echoes the workspace + requested surface).
    case workspaceNotFound
    /// The surface did not resolve (legacy `not_found` / "Surface not found",
    /// `data` echoes the workspace + requested surface).
    case surfaceNotFound
    /// The workspace is a remote workspace with no surfaces yet, so the kick was
    /// remembered (legacy `.ok` with `pending: true`, echoing the requested
    /// surface and the reason).
    case pending
    /// The port scanner was kicked. Carries the resolved surface id (the legacy
    /// `.ok` echoes the resolved surface, not the requested one).
    case kicked(surfaceID: UUID)
}
