import AppKit
import CmuxNextActions

/// Builds the menu bar from the action registry so menu titles and shortcuts
/// always match the palette and key router.
enum MainMenu {
    static func make(registry: ActionRegistry) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(Strings.appName, items: [
            NSMenuItem(title: Strings.menuAbout, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: Strings.menuHide, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            {
                let item = NSMenuItem(title: Strings.menuHideOthers, action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
                item.keyEquivalentModifierMask = [.command, .option]
                return item
            }(),
            NSMenuItem(title: Strings.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            registry.makeMenuItem(for: .quit),
        ]))
        mainMenu.addItem(submenu(Strings.menuFile, items: [
            registry.makeMenuItem(for: .newTab),
            registry.makeMenuItem(for: .closeTab),
        ]))
        mainMenu.addItem(submenu(Strings.menuView, items: [
            registry.makeMenuItem(for: .toggleSidebar),
            registry.makeMenuItem(for: .commandPalette),
        ]))
        let windowMenu = submenu(Strings.menuWindow, items: [
            NSMenuItem(title: Strings.menuMinimize, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: Strings.menuZoom, action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            .separator(),
            registry.makeMenuItem(for: .nextTab),
            registry.makeMenuItem(for: .previousTab),
        ])
        mainMenu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return mainMenu
    }

    private static func submenu(_ title: String, items: [NSMenuItem?]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for child in items.compactMap({ $0 }) {
            menu.addItem(child)
        }
        item.submenu = menu
        return item
    }
}
