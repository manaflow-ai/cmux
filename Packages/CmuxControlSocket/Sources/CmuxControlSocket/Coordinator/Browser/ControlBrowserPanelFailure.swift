public import Foundation

/// The failure ladder of the legacy `v2BrowserWithPanel` browser-surface
/// resolution. Each case maps onto exactly one legacy error result; the
/// coordinator owns that mapping so the wire bytes match.
public enum ControlBrowserPanelFailure: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// An explicit `pane_id` did not resolve to a pane (legacy `not_found` /
    /// "Pane not found", `data: {"pane_id": …}`).
    case paneNotFound(paneID: UUID)
    /// The explicit pane has no selected surface (legacy `not_found` /
    /// "Pane has no selected surface", `data: {"pane_id": …}`).
    case paneHasNoSelectedSurface(paneID: UUID)
    /// No explicit target and no focused surface (legacy `not_found` /
    /// "No focused browser surface").
    case noFocusedBrowserSurface
    /// The resolved surface is not a browser (legacy `invalid_params` /
    /// "Surface is not a browser", `data: {"surface_id": …}`).
    case surfaceNotBrowser(surfaceID: UUID)
}
