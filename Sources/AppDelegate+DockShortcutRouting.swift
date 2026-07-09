import AppKit
import CmuxSidebar
import CmuxPanes
import CmuxCommandPalette
import CmuxBrowser

/// Routes "create a surface" keyboard shortcuts (New Browser, New Terminal,
/// Split Right/Down) into the Dock when the Dock currently owns keyboard focus.
///
/// Without this, every creation shortcut targets the main content `tabManager`,
/// so pressing e.g. Cmd+Shift+L while a Dock pane is focused spawned a browser in
/// the main split tree instead of the Dock. Mirrors the existing focus-gated
/// routing in `closeFocusedDockPanelForCommand` (`Workspace+DockBrowserLookup.swift`):
/// the gate is `activeRightSidebarMode == .dock`, and the right-sidebar Dock is
/// that window's own Dock (`RightSidebarPanelView` renders the per-window store).
extension AppDelegate {
    /// The Dock store that should receive a creation/split shortcut when the Dock
    /// owns keyboard focus in `preferredWindow`, else `nil` (caller falls through
    /// to the main-area path).
    func focusedDockStoreForShortcut(preferredWindow: NSWindow?) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return nil
        }
        guard context.keyboardFocusCoordinator.activeRightSidebarMode == .dock else {
            return nil
        }
        // Dock mode showing means the right sidebar rendered this window's own
        // Dock (which created it), so this resolves the store already on screen.
        // No workspace-Dock fallback: the sidebar never renders one, so routing
        // a creation shortcut there would target an invisible tree.
        return windowDock(forWindowId: context.windowId)
    }

    /// Creates a New Terminal / New Browser surface in the focused Dock pane.
    /// Returns the created Dock panel id when handled, or `nil` to fall through to
    /// the main-area creation path.
    @discardableResult
    func routeCreateToFocusedDock(
        _ kind: DockSurfaceKind,
        focusAddressBar: Bool,
        preferredWindow: NSWindow?
    ) -> UUID? {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return nil
        }
        guard let store = focusedDockStoreForShortcut(preferredWindow: preferredWindow),
              let pane = store.resolvePane(requestedPaneID: nil),
              let panelId = store.newSurface(kind: kind, inPane: pane, focus: true) else {
            return nil
        }
        if focusAddressBar, kind == .browser, let browser = store.browserPanel(for: panelId) {
            focusBrowserAddressBar(in: browser)
        }
        return panelId
    }

    /// Splits the focused Dock pane (terminal or browser). Returns `true` when
    /// handled, or `false` to fall through to the main-area split path. Reuses the
    /// main area's `SplitDirection` → orientation/insert mapping so Dock splits
    /// match the main split affordances (Cmd+D = side-by-side, Cmd+Shift+D = stacked).
    @discardableResult
    func routeSplitToFocusedDock(
        kind: DockSurfaceKind,
        direction: SplitDirection,
        preferredWindow: NSWindow?
    ) -> Bool {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return false
        }
        guard let store = focusedDockStoreForShortcut(preferredWindow: preferredWindow) else {
            return false
        }
        return store.newSplit(
            kind: kind,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            sourcePanelId: store.focusedPanelId,
            focus: true
        ) != nil
    }
}
