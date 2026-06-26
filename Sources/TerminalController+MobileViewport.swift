import CMUXMobileCore
import Foundation

/// The app-target seam between ``TerminalController`` and the package-owned
/// mobile-terminal viewport state machine (``HostMobileViewportReportModel`` in
/// `CMUXMobileCore`).
///
/// The viewport-report state machine — per-surface, per-client reported grids
/// plus the TTL cleanup — moved out of the app target into `CMUXMobileCore`,
/// which owns it as a pure `@MainActor @Observable` model. What stays here is the
/// irreducible live-state seam: resolving a surface id through the live
/// `AppDelegate` / `TabManager` / `Workspace` graph and capping (or releasing)
/// its render grid via ``TerminalSurface``. `TerminalController` conforms to
/// ``MobileViewportSurfaceLimiting`` (published by the package) so the model can
/// drive that capping without reaching into the app graph itself.
///
/// The thin forwarders (`clearAllMobileViewportReports`,
/// `clearMobileViewportReports`, the `debug*ForTesting` helpers) are the model's
/// app-facing surface for the mobile host listener and the unit tests, which hold
/// a `TerminalController` rather than the `private` model. The
/// `applyMobileViewportReport` / `clearMobileViewportReport` parsers translate a
/// v2 control-plane request's piggybacked viewport fields into a model call; the
/// `v2*` param parsing stays app-side (shared v2 substrate) while the report
/// bookkeeping lives in the model.
extension TerminalController {
    func clearAllMobileViewportReports(reason: String) {
        mobileViewportReportModel.clearAll(reason: reason)
    }

    #if DEBUG
    func debugResetMobileViewportReportsForTesting() {
        mobileViewportReportModel.debugResetForTesting()
    }

    func debugSetMobileViewportReportForTesting(
        surfaceID: UUID,
        clientID: String,
        columns: Int,
        rows: Int,
        updatedAt: Date = Date()
    ) {
        mobileViewportReportModel.debugSetReportForTesting(
            surfaceID: surfaceID,
            clientID: clientID,
            columns: columns,
            rows: rows,
            updatedAt: updatedAt
        )
    }

    func debugMobileViewportReportClientIDsForTesting(surfaceID: UUID) -> Set<String>? {
        mobileViewportReportModel.debugReportClientIDsForTesting(surfaceID: surfaceID)
    }
    #endif

    private func terminalPanel(surfaceID: UUID) -> TerminalPanel? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        return workspace.terminalPanel(for: surfaceID)
    }

    // MARK: - MobileViewportSurfaceLimiting

    func applyMobileViewportLimit(surfaceID: UUID, columns: Int, rows: Int, reason: String) {
        terminalPanel(surfaceID: surfaceID)?.surface.applyMobileViewportLimit(
            columns: columns,
            rows: rows,
            reason: reason
        )
    }

    func clearMobileViewportLimit(surfaceID: UUID, reason: String) {
        terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
    }

    /// Parse the piggybacked viewport report off a `terminal.input` /
    /// `terminal.paste` request (or the dedicated viewport RPC when `sticky`) and
    /// hand the clamped values to ``mobileViewportReportModel``. The `v2*` param
    /// parsing stays here (shared v2 control-plane substrate); the report state
    /// machine lives in the model.
    func applyMobileViewportReport(
        params: [String: Any],
        terminalPanel: TerminalPanel,
        sticky: Bool = false
    ) {
        guard let clientID = v2String(params, "client_id"),
              let rawColumns = v2Int(params, "viewport_columns"),
              let rawRows = v2Int(params, "viewport_rows") else {
            return
        }
        mobileViewportReportModel.apply(
            surfaceID: terminalPanel.id,
            clientID: clientID,
            columns: rawColumns,
            rows: rawRows,
            sticky: sticky
        )
    }

    /// Remove a single client's viewport report for a surface (dedicated
    /// `mobile.terminal.viewport` clear, or a disconnect). Forwards to
    /// ``mobileViewportReportModel``.
    func clearMobileViewportReport(surfaceID: UUID, clientID: String, reason: String) {
        mobileViewportReportModel.clear(surfaceID: surfaceID, clientID: clientID, reason: reason)
    }

    /// Drop every viewport report owned by the given client IDs across all
    /// surfaces. Called when a mobile connection closes so a disconnected
    /// device stops pinning the grid even though it never sent an explicit
    /// clear. Sticky reports rely on this signal instead of the TTL. Forwards to
    /// ``mobileViewportReportModel``.
    func clearMobileViewportReports(clientIDs: Set<String>, reason: String) {
        mobileViewportReportModel.clear(clientIDs: clientIDs, reason: reason)
    }
}
