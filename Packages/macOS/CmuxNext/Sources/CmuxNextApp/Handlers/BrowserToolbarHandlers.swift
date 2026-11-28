import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// The browser toolbar's trailing buttons (`BrowserToolbarButtonsView`).
/// Every press runs a catalog action, so the palette, `cmux action run`,
/// the socket and the menus reach the same handler:
///
/// | button | action |
/// | --- | --- |
/// | design mode | `toggleBrowserDesignMode` |
/// | profile | `browser.profile.choose`, a menu of `browserProfile.moveTab` per profile |
/// | theme | a menu of `browserTheme` system, light, dark |
/// | DevTools | `toggleBrowserDeveloperTools` |
/// | More | `browser.overflow.menu` |
enum BrowserToolbarHandlers {
    /// The action a press runs. The theme button runs `browserTheme` from
    /// its menu, one item per scheme.
    static func actionID(for button: BrowserToolbarButton) -> ActionID {
        switch button {
        case .designMode: "toggleBrowserDesignMode"
        case .profile: "browser.profile.choose"
        case .theme: "browserTheme"
        case .devTools: "toggleBrowserDeveloperTools"
        case .overflow: "browser.overflow.menu"
        }
    }

    /// The `theme` argument of `browserTheme`; a missing or unknown
    /// value follows the app.
    static func colorScheme(_ invocation: ActionInvocation) -> BrowserColorScheme {
        invocation["theme"]?.stringValue.flatMap(BrowserColorScheme.init(rawValue:)) ?? .system
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browser.profile.choose", run: { invocation in
            let entry = try context.page(invocation)
            entry.chrome.toolbarButtons.present(profileMenu(for: entry, services: context.services), from: .profile)
        })
        registry.bind("browser.overflow.menu", run: { invocation in
            let entry = try context.page(invocation)
            entry.chrome.toolbarButtons.present(overflowMenu(for: entry, registry: registry), from: .overflow)
        })
    }

    /// Wires a new browser page's buttons (`TabContentCache.onBrowserEntryCreated`).
    static func install(on entry: BrowserEntry, services: AppServices) {
        let key = entry.tab.id.rawValue
        let buttons = entry.chrome.toolbarButtons
        buttons.onPress = { [weak services, weak entry] button in
            guard let services, let entry else { return }
            press(button, entry: entry, registry: services.registry)
        }
        buttons.shortcutHint = { [weak services] button in
            guard button == .designMode || button == .devTools else { return nil }
            return services?.registry.shortcutDisplay(for: actionID(for: button))
        }
        buttons.profileName = profileName(forTab: key, services: services)
    }

    static func press(_ button: BrowserToolbarButton, entry: BrowserEntry, registry: ActionRegistry) {
        let target = tabTarget(entry)
        if button == .theme {
            return entry.chrome.toolbarButtons.present(themeMenu(target: target, registry: registry), from: .theme)
        }
        registry.perform(actionID(for: button), invocation: ActionInvocation(target: target, origin: .user))
    }

    static func profileName(forTab key: String, services: AppServices) -> String {
        services.browserProfiles.displayName(services.cache.tabModel(key).map(services.browserProfiles.profileID(ofTab:)))
    }

    private static func tabTarget(_ entry: BrowserEntry) -> ActionTargetRef {
        ActionTargetRef(kind: .tab, id: entry.tab.id.rawValue)
    }

    /// System, Light and Dark, each running `browserTheme`; the
    /// current scheme is checked (`ThemeCoordinator.currentChoice`).
    static func themeMenu(target: ActionTargetRef, registry: ActionRegistry) -> NSMenu {
        let built = registry.makeContextMenu(for: .browserPage, target: target, entries: [.choices("browserTheme")])
        // The registry keeps the choices' hover-preview delegate alive as
        // long as this submenu, so the submenu itself is shown.
        guard let item = built.items.first, let submenu = item.submenu else { return built }
        item.submenu = nil
        return submenu
    }

    /// One item per browser profile (the tab's checked), each moving the tab
    /// with `browserProfile.moveTab`; then New Browser Profile, Import from
    /// Browser and Rename Browser Profile for the tab's profile.
    static func profileMenu(for entry: BrowserEntry, services: AppServices) -> NSMenu {
        let registry = services.registry
        let target = tabTarget(entry)
        let profiles = services.browserProfiles
        let current = services.cache.tabModel(entry.tab.id.rawValue).map(profiles.profileID(ofTab:)) ?? BrowserProfileRecord.defaultID
        let menu = NSMenu()
        for record in profiles.ordered {
            let item = NSMenuItem(title: record.icon.map { "\($0)  \(record.name)" } ?? record.name, action: nil, keyEquivalent: "")
            item.state = record.id == current ? .on : .off
            let closure = ActionMenuClosure { [weak registry] in
                guard record.id != current else { return }
                registry?.perform("browserProfile.moveTab", invocation: ActionInvocation(
                    target: target, arguments: ["browserProfile": .string(record.id)], origin: .user))
            }
            item.target = closure
            item.action = #selector(ActionMenuClosure.run)
            item.representedObject = closure
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let profileTarget = ActionTargetRef(kind: .browserProfile, id: current)
        let entries: [ContextMenuEntry] = [.action("browserProfile.new"), .action("importFromBrowser")]
        move(registry.makeContextMenu(for: .browserPage, target: target, entries: entries), into: menu)
        move(registry.makeContextMenu(for: .browserProfile, target: profileTarget, entries: [.action("browserProfile.rename")]), into: menu)
        return menu
    }

    private static func move(_ source: NSMenu, into menu: NSMenu) {
        for item in source.items {
            source.removeItem(item)
            menu.addItem(item)
        }
    }

    /// The classic browser pane's More menu: the collapsed buttons' actions
    /// first, then focus mode, screenshots, open elsewhere and import.
    static func overflowMenu(for entry: BrowserEntry, registry: ActionRegistry) -> NSMenu {
        var entries: [ContextMenuEntry] = []
        for button in entry.chrome.toolbarButtons.collapsedButtons {
            switch button {
            case .designMode: entries.append(.action("toggleBrowserDesignMode"))
            case .devTools: entries.append(.action("toggleBrowserDeveloperTools"))
            case .profile: entries.append(.action("browser.profile.choose"))
            case .theme: entries.append(.choices("browserTheme"))
            case .overflow: break
            }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries += [
            .action("toggleBrowserFocusMode"), .action("browserScreenshotPage"), .action("browserScreenshotSection"), .separator,
            .action("palette.browserOpenDefault"),
            .action(entry.tab.engineKind == .cef ? "browser.openInWebKit" : "browser.openInChromium"), .separator,
            .action("importFromBrowser"),
        ]
        return registry.makeContextMenu(for: .browserPage, target: tabTarget(entry), entries: entries)
    }
}
