public import Foundation

/// The outcome of the app-side `browser.tab.close`, preserving the legacy
/// body's distinct failures.
public enum ControlBrowserTabCloseResolution: Sendable, Equatable {
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// The workspace has no browser tabs (legacy `not_found` /
    /// "No browser tabs").
    case noBrowserTabs
    /// No matching browser tab (legacy `not_found` / "Browser tab not found").
    case tabNotFound
    /// Closing would remove the last surface (legacy `invalid_state` /
    /// "Cannot close the last surface").
    case lastSurface
    /// The close failed (legacy `internal_error` /
    /// "Failed to close browser tab", `data: {"surface_id": …}`).
    case closeFailed(surfaceID: UUID)
    /// The tab closed.
    case closed(workspaceID: UUID, surfaceID: UUID)
}
