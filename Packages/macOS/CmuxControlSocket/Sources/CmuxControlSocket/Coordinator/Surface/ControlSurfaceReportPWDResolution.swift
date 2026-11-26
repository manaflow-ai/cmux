public import Foundation

/// The outcome of `surface.report_pwd`, preserving the report commands'
/// distinct failures and recorded identity.
///
/// The coordinator validates the params (workspace required, surface-if-present
/// must parse, path required) and mints refs; every case echoes the workspace id
/// plus the requested-or-resolved surface id and the path. The app records the
/// current working directory against the resolved surface and returns this.
public enum ControlSurfaceReportPWDResolution: Sendable, Equatable {
    /// The workspace did not resolve (`not_found` / "Workspace not found",
    /// `data` echoes the workspace + requested surface).
    case workspaceNotFound
    /// The surface did not resolve (`not_found` / "Surface not found", `data`
    /// echoes the workspace + requested surface).
    case surfaceNotFound
    /// The workspace is a remote workspace with no surfaces yet, so the path was
    /// remembered (`ok` with `pending: true`, echoing the requested surface).
    case pending
    /// The path was recorded. Carries the resolved surface id (the `.ok` payload
    /// echoes the resolved surface, not the requested one).
    case recorded(surfaceID: UUID)
}
