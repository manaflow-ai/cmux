public import Foundation

/// The shared resolution-failure categories of the legacy
/// `TerminalController.v2BrowserWithPanel` head, surfaced as a typed value so
/// the coordinator (not the witness) emits the byte-identical `.err` payload.
///
/// Every panel-resolving `browser.*` command (cookies / storage / state / frame
/// / dialog / addinitscript / addscript / addstyle) shared the same four-step
/// resolution: `v2ResolveTabManager` → `v2ResolveWorkspace` →
/// `v2ResolveBrowserSurfaceId` → `Workspace.browserPanel(for:)`. When any step
/// fails, the legacy body returned the corresponding `.err`. These witnesses
/// reproduce that resolution and report the failure category here; the
/// coordinator maps each case to the exact legacy code/message/data.
public enum ControlBrowserPanelResolutionFailure: Sendable, Equatable {
    /// `v2ResolveTabManager` returned nil
    /// (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// `v2ResolveWorkspace` returned nil
    /// (`not_found` / "Workspace not found").
    case workspaceNotFound
    /// `v2ResolveBrowserSurfaceId` returned a pane-resolution error
    /// (`not_found` / "Pane not found", data `{"pane_id": …}`).
    case paneNotFound(paneID: UUID)
    /// `v2ResolveBrowserSurfaceId` resolved a pane but it held no selected
    /// surface (`not_found` / "Pane has no selected surface",
    /// data `{"pane_id": …}`).
    case paneHasNoSelectedSurface(paneID: UUID)
    /// No `surface_id`/`pane_id` given and no focused browser surface
    /// (`not_found` / "No focused browser surface").
    case noFocusedBrowserSurface
    /// The resolved surface is not a browser
    /// (`invalid_params` / "Surface is not a browser", data `{"surface_id": …}`).
    case surfaceNotBrowser(surfaceID: UUID)
}
