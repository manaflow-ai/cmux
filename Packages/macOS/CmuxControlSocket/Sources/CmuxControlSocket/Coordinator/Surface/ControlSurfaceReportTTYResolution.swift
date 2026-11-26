public import Foundation

/// The outcome of `surface.report_tty`, preserving the legacy body's distinct
/// failures and the recorded identity.
///
/// The coordinator validates the params (workspace required, surface-if-present
/// must parse, tty_name required) and mints the workspace/surface refs; every case
/// echoes the workspace id plus the requested-or-resolved surface id. The app
/// records the TTY name (locally or against the remote workspace) and returns this.
public enum ControlSurfaceReportTTYResolution: Sendable, Equatable {
    /// The workspace did not resolve (legacy `not_found` / "Workspace not found",
    /// `data` echoes the workspace + requested surface).
    case workspaceNotFound
    /// The surface did not resolve (legacy `not_found` / "Surface not found",
    /// `data` echoes the workspace + requested surface).
    case surfaceNotFound
    /// The workspace is a remote workspace with no surfaces yet, so the TTY was
    /// remembered (legacy `.ok` with `pending: true`, echoing the requested
    /// surface).
    case pending
    /// The TTY name was recorded. Carries the resolved surface id (the legacy `.ok`
    /// echoes the resolved surface, not the requested one).
    case recorded(surfaceID: UUID)
}
