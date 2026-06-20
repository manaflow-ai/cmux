public import Foundation

/// A single workspace's React Grab surface, as ``ReactGrabController`` needs it.
///
/// TabManager owns the per-window workspace state (panels, focus, split zoom)
/// and the app-target panel model, so the workspace cannot move into a package.
/// The app target adapts a `Workspace` to this protocol so the controller can
/// resolve and drive a React Grab toggle without importing the app target.
///
/// Route computation (`reactGrabRouteFromFocus`) stays app-side because it is
/// keyed on the app-target panel-type model; everything else the controller
/// drives through this seam.
///
/// `@MainActor` because every member reads or mutates AppKit/WebKit-backed
/// per-window state on the main thread, matching the controller's callers.
@MainActor
public protocol ReactGrabWorkspaceContext: AnyObject {
    /// The workspace's identity (used for diagnostic logging).
    var reactGrabWorkspaceId: UUID { get }

    /// The currently focused panel id, if any.
    var reactGrabFocusedPanelId: UUID? { get }

    /// The React Grab route resolved from the focused panel layout, if one
    /// exists. Computed app-side from the panel-type model.
    func reactGrabRouteFromFocus() -> ReactGrabRoute?

    /// The browser-acting panel for `panelId`, or `nil` if `panelId` is not a
    /// browser panel in this workspace.
    func reactGrabBrowserActing(for panelId: UUID) -> (any ReactGrabBrowserActing)?

    /// Whether `panelId` is a terminal panel in this workspace.
    func reactGrabPanelIsTerminal(_ panelId: UUID) -> Bool

    /// Clears split zoom (used before focusing the browser panel).
    func reactGrabClearSplitZoom()

    /// Focuses the given panel.
    func reactGrabFocusPanel(_ panelId: UUID)
}
