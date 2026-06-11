public import Foundation

/// The outcome of resolving the browser panel a DOM-automation command targets
/// (the legacy `v2BrowserWithPanel` / `v2ResolveBrowserSurfaceId` precedence),
/// with one case per distinct legacy failure so the coordinator can preserve
/// every error code/message/data shape exactly.
public enum ControlBrowserPanelResolution: Sendable, Equatable {
    /// No `TabManager` could be resolved (`unavailable`).
    case tabManagerUnavailable
    /// The routed workspace was not found (`not_found`).
    case workspaceNotFound
    /// An explicit `pane_id` did not match a pane (`not_found` + `pane_id`).
    case paneNotFound(UUID)
    /// The pane exists but has no selected surface (`not_found` + `pane_id`).
    case paneHasNoSelectedSurface(UUID)
    /// No explicit surface and the workspace has no focused surface
    /// (`not_found`).
    case noFocusedBrowserSurface
    /// The resolved surface is not a browser (`invalid_params` + `surface_id`).
    case surfaceNotBrowser(UUID)
    /// The target browser surface, with its owning workspace.
    case resolved(workspaceID: UUID, surfaceID: UUID)
}
