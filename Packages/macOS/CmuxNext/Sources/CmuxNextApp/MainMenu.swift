import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettingsWindow

/// Builds the menu bar from the action registry (`mainMenu` placements) so
/// titles and shortcuts match the palette and key router. Edit keeps the
/// standard responder-chain items so text fields (rename, omnibox) work;
/// the Help menu is in MainMenu+Placements.swift.
enum MainMenu {
    /// - Parameter customizations: App menu > Customizations (`CustomizationsMenu`), placed under Customize….
    static func make(registry: ActionRegistry, customizations: NSMenuItem? = nil) -> NSMenu {
        let mainMenu = NSMenu()
        // About (`about`: the standard panel with the build's credits) comes first, as in every Mac app.
        var app: [NSMenuItem] = registry.makeMenuItem(for: "about").map { [$0, .separator()] } ?? []
        // Keep the app menu to the primary settings/update controls. One Quit (CMUX-630, Leo
        // 2026-11-15: "we should just have the one quit"): Quit cmux (Cmd-Q) is the Dock's Quit, quits
        // the app only and never asks. The quits that end the sessions are palette rows and CLI flags.
        let quitIDs: [ActionID] = ["quit"]
        let placedElsewhere = Set((quitIDs + [ActionID("about")]).compactMap { registry.title(for: $0) })
        app += compactMainMenuItems(for: .app, registry: registry).filter { !placedElsewhere.contains($0.title) }
        if let customizations { app = CustomizationsMenu.inserting(customizations, into: app, after: [registry.title(for: "customize.open"), registry.title(for: "openSettings")]) }
        app += [
            .separator(),
            NSMenuItem(title: Strings.menuHide, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            item(Strings.menuHideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            NSMenuItem(title: Strings.menuShowAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
        ]
        app += quitIDs.compactMap { registry.makeMenuItem(for: $0) }
        mainMenu.addItem(submenu(Strings.appName, items: app))
        mainMenu.addItem(submenu(Strings.menuFile, items: compactMainMenuItems(for: .file, registry: registry)))
        mainMenu.addItem(submenu(Strings.menuEdit, items: [
            item(Strings.menuUndo, Selector(("undo:")), "z", [.command]),
            item(Strings.menuRedo, Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(Strings.menuCut, #selector(NSText.cut(_:)), "x", [.command]),
            item(Strings.menuCopy, #selector(NSText.copy(_:)), "c", [.command]),
            item(Strings.menuPaste, #selector(NSText.paste(_:)), "v", [.command]),
            // Cmd+Shift+V, as in Chrome and Slack (Lawrence 2026-10-20): plain text only, in any text input.
            item(Strings.menuPasteAndMatchStyle, #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .shift]),
            // Opt-Shift-Cmd-V, the macOS standard Chrome also keeps (an alternate: shown with Option held).
            alternate(item(Strings.menuPasteAndMatchStyle, #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .shift, .option])),
            item(Strings.menuSelectAll, #selector(NSText.selectAll(_:)), "a", [.command]),
        ]))
        mainMenu.addItem(submenu(Strings.menuView, items: compactMainMenuItems(for: .view, registry: registry)))
        let server = compactMainMenuItems(for: .server, registry: registry)
        if !server.isEmpty { mainMenu.addItem(submenu(Strings.menuServer, items: server)) }
        // Zoom (`zoomWindow`) sits under Minimize, as in every Mac app.
        let zoomTitle = registry.title(for: "zoomWindow")
        let windowMenu = submenu(Strings.menuWindow, items: [
            item(Strings.menuMinimize, #selector(NSWindow.performMiniaturize(_:)), "m", [.command]),
            registry.makeMenuItem(for: "zoomWindow")
                ?? NSMenuItem(title: Strings.menuZoom, action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
        ] + [
            .separator(),
        ] + compactMainMenuItems(for: .window, registry: registry).filter { $0.title != zoomTitle })
        mainMenu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        // No Debug menu: debug-only actions are Command Palette rows, shown while Internal Developer Mode
        // is on (`DebugActionGate`).
        // Help, last as on every Mac: macOS adds its search field to `NSApp.helpMenu`.
        let helpMenu = submenu(Strings.menuHelp, items: helpPlacements(registry))
        mainMenu.addItem(helpMenu)
        NSApp.helpMenu = helpMenu.submenu
        return mainMenu
    }

    /// The compact Release menu keeps the common path visible while every catalog action
    /// remains available through the command palette. Every catalog `main_menu` placement is either
    /// here or palette-only by a reason in the catalog's tests/main_menu_bar.rs, so none goes missing silently.
    static let compactActionIDs: [ActionMainMenu: [ActionID]] = [
        .app: [
            "about", "openSettings", "customize.open", "home.showSetup", "palette.checkForUpdates", "updates.installEarlierBuild", "keepMacAwake", "quit",
        ],
        .file: [
            "newTab", "newBrowserWorkspace", "newTab.default", "palette.newAgentChat", "palette.quickAgentChat",
            "openFolder", "file.open", "macScreen.open", "remote.connect", "device.add", "closeTab", "closeWorkspace", "closeWindow",
            "reopenClosedWorkspace", "reopenClosedBrowserPanel", "home.stopAllAgents",
        ],
        .view: [
            "browserBack", "browserForward", "browserReload", "browserStop", "browserHardReload",
            "browserZoomIn", "browserZoomOut", "browserZoomReset", "toggleSidebar",
            "appearance.customize",
        ],
        .server: ["server.addServer", "server.showPanel"],
        .window: [
            "newWindow", "newIncognitoWindow", "window.mergeAll", "space.new", "space.previous", "space.next", "toggleFullScreen", "commandPalette", "goToWorkspace",
            "globalSearch", "showMainWindow",
        ],
        .help: ["help.documentation", "palette.searchShortcuts", "updates.whatsNew", "sendFeedback", "help.showCrashLogs"],
    ]

    /// IDs intentionally removed from the menu bar; they stay in the searchable palette.
    static var removedMainMenuActionIDs: Set<ActionID> {
        let kept = Set(compactActionIDs.values.flatMap { $0 })
        return Set(ActionCatalog.all.compactMap { descriptor in
            guard descriptor.mainMenu != nil, !kept.contains(descriptor.id) else { return nil }
            return descriptor.id
        })
    }

    /// Builds one compact menu while retaining the catalog's category separators.
    static func compactMainMenuItems(for menu: ActionMainMenu, registry: ActionRegistry) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        var lastCategory: ActionCategory?
        for id in compactActionIDs[menu, default: []] {
            guard let descriptor = registry.descriptor(for: id), descriptor.mainMenu == menu,
                  let item = registry.makeMenuItem(for: id) else { continue }
            if let lastCategory, lastCategory != descriptor.category { items.append(.separator()) }
            lastCategory = descriptor.category
            items.append(item)
        }
        return items
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isAlternate = true
        return item
    }

    static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        var previousSeparator = true
        for child in items {
            if child.isSeparatorItem, previousSeparator { continue }
            menu.addItem(child)
            previousSeparator = child.isSeparatorItem
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        item.submenu = menu
        return item
    }
}
