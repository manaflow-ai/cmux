import AppKit
import CmuxNextActions

/// Builds the menu bar from the action registry (`mainMenu` placements) so
/// titles and shortcuts match the palette and key router. Edit keeps the
/// standard responder-chain items so text fields (rename, omnibox) work.
enum MainMenu {
    static func make(registry: ActionRegistry) -> NSMenu {
        let mainMenu = NSMenu()
        var app: [NSMenuItem] = [
            NSMenuItem(title: Strings.menuAbout, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
        ]
        let quitTitle = registry.title(for: "quit")
        app += registry.makeMainMenuItems(for: .app).filter { $0.title != quitTitle }
        app += [
            .separator(),
            NSMenuItem(title: Strings.menuHide, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            item(Strings.menuHideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            NSMenuItem(title: Strings.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
        ]
        if let quit = registry.makeMenuItem(for: "quit") { app.append(quit) }
        mainMenu.addItem(submenu(Strings.appName, items: app))
        mainMenu.addItem(submenu(Strings.menuFile, items: registry.makeMainMenuItems(for: .file)))
        mainMenu.addItem(submenu(Strings.menuEdit, items: [
            item(Strings.menuUndo, Selector(("undo:")), "z", [.command]),
            item(Strings.menuRedo, Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(Strings.menuCut, #selector(NSText.cut(_:)), "x", [.command]),
            item(Strings.menuCopy, #selector(NSText.copy(_:)), "c", [.command]),
            item(Strings.menuPaste, #selector(NSText.paste(_:)), "v", [.command]),
            item(Strings.menuSelectAll, #selector(NSText.selectAll(_:)), "a", [.command]),
        ]))
        mainMenu.addItem(submenu(Strings.menuView, items: registry.makeMainMenuItems(for: .view)))
        let windowMenu = submenu(Strings.menuWindow, items: [
            item(Strings.menuMinimize, #selector(NSWindow.performMiniaturize(_:)), "m", [.command]),
            NSMenuItem(title: Strings.menuZoom, action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            .separator(),
        ] + registry.makeMainMenuItems(for: .window))
        mainMenu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return mainMenu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        var previousSeparator = true
        for child in items {
            if child.isSeparatorItem, previousSeparator { continue }
            menu.addItem(child)
            previousSeparator = child.isSeparatorItem
        }
        item.submenu = menu
        return item
    }
}
