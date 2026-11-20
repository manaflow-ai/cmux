import AppKit
import CmuxNextDesign

/// The one way the sidebar opens a menu, so `sidebar.drawnMenus` reaches every one of them: with it on,
/// the menu opens as a `GlassMenu` (which the menu look styles); off, as the system menu, as before.
/// The App builds those menus without their name-and-swatches header while the setting is on
/// (`MenuIdentityHeader.install`, a row view a `GlassMenu` does not draw), so a sidebar menu that still
/// opened as a system menu would lose its header for nothing (review of #46879, F1).
extension NSView {
    /// A right-click's menu, for `menu(for:)`: with drawn menus on, shows `menu` at the pointer as a
    /// `GlassMenu` and answers nil (AppKit then shows none); else, or when it cannot show, answers `menu`.
    func sidebarContextMenu(_ menu: NSMenu?, for event: NSEvent) -> NSMenu? {
        guard let menu, DesignSettings.shared.sidebarDrawnMenus, let window else { return menu }
        let at = window.convertPoint(toScreen: event.locationInWindow)
        return GlassMenu(menu: menu).show(at: CGRect(origin: at, size: .zero), in: window, preferred: .below) ? nil : menu
    }

    /// A right-click's menu a view opens itself (`NSMenu.popUpContextMenu`): drawn when the setting is on.
    func popUpSidebarContextMenu(_ menu: NSMenu, with event: NSEvent) {
        guard let menu = sidebarContextMenu(menu, for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Shows `menu` under `rect` (in this view) as a `GlassMenu` when drawn menus are on. Answers whether it
    /// did; false leaves the caller to pop up the system menu. `onClose` runs once the drawn menu closes.
    func showDrawnSidebarMenu(_ menu: NSMenu, under rect: CGRect, onClose: (() -> Void)? = nil) -> Bool {
        guard DesignSettings.shared.sidebarDrawnMenus, let window else { return false }
        let glass = GlassMenu(menu: menu)
        glass.onClose = onClose
        return glass.show(at: window.convertToScreen(convert(rect, to: nil)), in: window, preferred: .below)
    }
}
