import Foundation

/// The seam through which ``HostMobileViewportReportModel`` drives a terminal
/// surface's shared mobile viewport limit without reaching into the live
/// `Workspace` / `TabManager` / `AppDelegate` graph itself.
///
/// The viewport-report state machine is pure bookkeeping (per-surface, per-client
/// reported grids plus their TTL) and the only side effect it performs is capping
/// or clearing the surface's render grid so the macOS letterbox border matches the
/// smallest attached device. That capping lives on `TerminalSurface`
/// (`applyMobileViewportLimit` / `clearMobileViewportLimit`), reached from a
/// surface id through the app's live surface lookup. Inverting it behind this
/// protocol keeps the model free of the app-target singletons so it owns only its
/// own state, and lets tests substitute a recording limiter.
///
/// Conformed by `TerminalController` (the app-target composition owner), which
/// resolves the surface and forwards to the existing `TerminalSurface` API. The
/// id passed here is the terminal surface / panel id; for the input-piggyback
/// apply path the caller already holds the resolved panel, whose `id` equals this
/// surface id, so resolving by id is byte-faithful to the legacy direct call.
@MainActor
protocol MobileViewportSurfaceLimiting: AnyObject {
    /// Cap the resolved surface's render grid to `columns` x `rows`, drawing the
    /// macOS viewport border when the pane is larger. No-op when the surface is
    /// not currently live.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal surface id to cap.
    ///   - columns: The shared-minimum column count across attached devices.
    ///   - rows: The shared-minimum row count across attached devices.
    ///   - reason: A debug/telemetry reason string forwarded to the surface.
    func applyMobileViewportLimit(surfaceID: UUID, columns: Int, rows: Int, reason: String)

    /// Remove any mobile viewport cap from the resolved surface so it renders at
    /// its native pane grid again. No-op when the surface is not currently live.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal surface id to release.
    ///   - reason: A debug/telemetry reason string forwarded to the surface.
    func clearMobileViewportLimit(surfaceID: UUID, reason: String)
}
