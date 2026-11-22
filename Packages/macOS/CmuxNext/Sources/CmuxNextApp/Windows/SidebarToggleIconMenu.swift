import AppKit
import CmuxNextDesign

/// Debug menu > Sidebar Toggle Icon (DEV and NIGHTLY, `DevTools`): one item
/// per `SidebarToggleIcon` candidate, with its sidebar-shown glyph and a
/// check on the current one. Choosing writes the Debug Settings tunable, so
/// every window's toggle changes at once and the choice persists in the
/// build's debug-tunables.json. Choosing the default removes the override.
final class SidebarToggleIconMenu: NSObject, NSMenuDelegate {
    static let shared = SidebarToggleIconMenu()

    /// Where the choice is written (tests pass their own store).
    var store: TunableStore = .shared

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: Strings.menuSidebarToggleIcon, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: Strings.menuSidebarToggleIcon)
        menu.delegate = self
        for icon in SidebarToggleIcon.allCases {
            let choice = NSMenuItem(title: icon.tunableTitle, action: #selector(choose(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = icon.rawValue
            let name = icon.symbol(sidebarHidden: false)
            choice.image = SidebarToggleIcon.image(named: name, pointSize: Metrics.smallIconSize)
                ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
            menu.addItem(choice)
        }
        item.submenu = menu
        updateStates(in: menu)
        return item
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let icon = SidebarToggleIcon(rawValue: raw) else { return }
        select(icon)
    }

    /// Sets the icon; the default clears the override.
    func select(_ icon: SidebarToggleIcon) {
        let key = SidebarToggleIcon.tunable.key
        if icon == SidebarToggleIcon.tunable.defaultValue {
            store.reset([key])
        } else {
            store.set(key, icon.tunableValue)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStates(in: menu)
    }

    private func updateStates(in menu: NSMenu) {
        let current = SidebarToggleIcon.tunable.value(in: store).rawValue
        for item in menu.items {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
    }
}
