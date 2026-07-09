public import Foundation

/// The per-workspace operations ``ClosedBrowserPanelReopenCoordinator`` drives
/// against a single target workspace when restoring a recently-closed browser
/// panel (Cmd+Shift+T legacy stack path).
///
/// The concrete workspace lives in the app target (it owns the Bonsplit split
/// tree, the WebKit `BrowserPanel` instances, and the focus/layout state), so a
/// lower package cannot import it. Instead the app-target workspace conforms to
/// this protocol and the coordinator forwards each lookup/mutation through it,
/// receiving the restored panel's id (`UUID`) rather than the app-owned panel
/// reference.
///
/// ``reopenClosedBrowserPanel(_:)`` is the single seam for the whole
/// bonsplit-coupled placement walk the legacy
/// `TabManager.reopenClosedBrowserPanel(_:in:)` performed: original-pane reuse,
/// the fallback split against a remembered anchor, and the focused-or-first-pane
/// last resort. It stays app-side (mirroring how `BrowserOpenWorkspaceHandle`
/// keeps `newBrowserSurface`/`newBrowserSplit` app-side) because every step
/// reads or mutates the workspace's `bonsplitController`, `reorderSurface`,
/// `panelIdFromSurfaceId`, and surface-creation state, none of which can move
/// down. ``focusedPanelId``, ``hasPanel(_:)``, and ``focusPanel(_:)`` are the
/// focus-reconciliation reads/writes the post-reopen focus enforcement performs.
///
/// `@MainActor` because every operation mutates WebKit/AppKit/Bonsplit state on
/// the main thread, matching the caller (the Cmd+Shift+T reopen turn) — the seam
/// lives where its callers live.
@MainActor
public protocol ClosedBrowserPanelReopenWorkspaceHandle: AnyObject {
    /// The workspace's currently focused panel id, if any
    /// (legacy `tab.focusedPanelId`).
    var focusedPanelId: UUID? { get }

    /// Whether the workspace currently holds a panel with `panelId`
    /// (legacy `tab.panels[panelId] != nil`).
    func hasPanel(_ panelId: UUID) -> Bool

    /// Focuses `panelId` within the workspace (legacy `tab.focusPanel(panelId)`).
    func focusPanel(_ panelId: UUID)

    /// Restores a recently-closed browser panel back into its original
    /// placement, returning the restored panel's id, or `nil` when no surface
    /// could be created. Byte-faithful to the legacy
    /// `TabManager.reopenClosedBrowserPanel(_:in:)` three-tier walk.
    func reopenClosedBrowserPanel(_ snapshot: ClosedBrowserPanelRestoreSnapshot) -> UUID?
}
