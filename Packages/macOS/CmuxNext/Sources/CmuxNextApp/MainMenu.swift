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
        // Quit and its two session choices go last, below Show All.
        let quitIDs: [ActionID] = ["quit", "quitKeepSessions", "quitEndSessions", "quitEndEverything"]
        let quitTitles = Set(quitIDs.compactMap { registry.title(for: $0) })
        app += registry.makeMainMenuItems(for: .app).filter { !quitTitles.contains($0.title) }
        app += [
            .separator(),
            NSMenuItem(title: Strings.menuHide, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            item(Strings.menuHideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            NSMenuItem(title: Strings.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
        ]
        app += quitIDs.compactMap { registry.makeMenuItem(for: $0) }
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
        let server = registry.makeMainMenuItems(for: .server)
        if !server.isEmpty { mainMenu.addItem(submenu(Strings.menuServer, items: server)) }
        // Zoom (`zoomWindow`) sits under Minimize, as in every Mac app.
        let zoomTitle = registry.title(for: "zoomWindow")
        let windowMenu = submenu(Strings.menuWindow, items: [
            item(Strings.menuMinimize, #selector(NSWindow.performMiniaturize(_:)), "m", [.command]),
            registry.makeMenuItem(for: "zoomWindow")
                ?? NSMenuItem(title: Strings.menuZoom, action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
        ] + [
            .separator(),
        ] + registry.makeMainMenuItems(for: .window).filter { $0.title != zoomTitle })
        mainMenu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        // Debug (DEV and NIGHTLY, `DevTools`): debug-only actions placed there.
        var debug = DevTools.isEnabled ? registry.makeMainMenuItems(for: .debug) : []
        if DevTools.isEnabled { debug += [.separator(), SidebarToggleIconMenu.shared.makeItem()] }
        if !debug.isEmpty { mainMenu.addItem(submenu(Strings.menuDebug, items: debug)) }
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
