import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextSettings

/// The browser toolbar's trailing buttons (`BrowserToolbarButtonsView`).
/// Every press runs a catalog action, so the palette, `cmux action run`,
/// the socket and the menus reach the same handler:
///
/// | button | action |
/// | --- | --- |
/// | media hub | `browser.media.show`, the media hub (`BrowserMediaMenu`) |
/// | zoom | `browserZoomReset` |
/// | Favorites | `bookmark.manager` |
/// | Downloads | `browser.downloads.show`, the downloads popup (`BrowserDownloadsPopup`) |
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
        case .media: "browser.media.show"
        case .zoom: "browserZoomReset"
        case .favorites: "bookmark.manager"
        case .downloads: "browser.downloads.show"
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
        registry.bind("browser.media.show", run: { invocation in
            let entry = try context.page(invocation)
            entry.chrome.toolbarButtons.present(BrowserMediaMenu.menu(context.services, rows: entry.chrome.toolbarButtons.mediaRows), from: .media)
        })
        registry.bind("browser.downloads.show", run: { invocation in
            let entry = try context.page(invocation)
            showDownloads(for: entry, services: context.services, finished: false)
        })
        registry.bind("browser.overflow.menu", run: { invocation in
            let entry = try context.page(invocation)
            entry.chrome.toolbarButtons.present(overflowMenu(for: entry, registry: registry, settings: context.services.settings), from: .overflow)
        })
    }

    /// Wires a new browser page's buttons (`TabContentCache.onBrowserEntryCreated`).
    static func install(on entry: BrowserEntry, services: AppServices) {
        let key = tabKey(entry)
        let buttons = entry.chrome.toolbarButtons
        buttons.onPress = { [weak services, weak entry] button in
            guard let services, let entry else { return }
            press(button, entry: entry, registry: services.registry)
        }
        buttons.shortcutHint = { [weak services] button in
            guard [.media, .zoom, .favorites, .downloads, .designMode, .devTools].contains(button) else { return nil }
            return services?.registry.shortcutDisplay(for: actionID(for: button))
        }
        buttons.profileName = profileName(forTab: key, services: services)
        buttons.downloads = { [weak services] in
            services?.cache.pageRequests.downloads.toolbarSummary(forTab: key) ?? BrowserToolbarDownloads()
        }
        buttons.media = { [weak services] in services.map { $0.cache.pageRequests.media.toolbar(in: $0.cache) } ?? BrowserToolbarMedia() }
        buttons.pins = { [weak services] in (services?.settings.map(BrowserToolbarButtonsSetting.current) ?? .fallback).pinned }
        // The omnibar's "Focus Mode" badge leaves focus mode (the action's one path).
        entry.chrome.onFocusModeBadgePress = { [weak services, weak entry] in
            guard let services, let entry else { return }
            services.registry.perform("toggleBrowserFocusMode", invocation: ActionInvocation(target: tabTarget(entry), origin: .user))
        }
    }

    /// Opens (or closes) the Downloads popup under `entry`'s Downloads
    /// button. With `finished` (a download of that tab just finished) it
    /// opens without the keys and closes by itself, and only while the tab's
    /// toolbar is on screen in the active window: false when it did not
    /// open, so the caller shows the notice over the tab instead.
    @discardableResult
    static func showDownloads(for entry: BrowserEntry, services: AppServices, finished: Bool) -> Bool {
        let buttons = entry.chrome.toolbarButtons
        let target = tabTarget(entry)
        let showFolder = { [weak services] in
            _ = services?.registry.perform("browser.downloads.showFolder", invocation: ActionInvocation(target: target, origin: .user))
        }
        let list = services.cache.pageRequests.downloads
        buttons.refresh()
        if finished { return BrowserDownloadsPopup.shared.showFinished(list, buttons: buttons, showFolder: showFolder) }
        BrowserDownloadsPopup.shared.toggle(list, buttons: buttons, showFolder: showFolder)
        return true
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
        ActionTargetRef(kind: .tab, id: tabKey(entry))
    }

    /// The tab id the App keys `entry` by (`TabContentCache`): the address
    /// bar's, which an adopted page (a popup or link opened into a new tab)
    /// keeps although its own page id differs.
    private static func tabKey(_ entry: BrowserEntry) -> String {
        entry.chrome.addressBar.tabKey ?? entry.tab.id.rawValue
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
        // This profile's own extensions (chrome://extensions and the Web Store open in it).
        move(registry.makeContextMenu(for: .browserPage, target: target,
                                      entries: [.separator, .action("browser.extensions.manage"), .action("browser.extensions.webStore")]), into: menu)
        return menu
    }

    private static func move(_ source: NSMenu, into menu: NSMenu) {
        for item in source.items {
            source.removeItem(item)
            menu.addItem(item)
        }
    }

    /// The More menu (cx-6qwm): buttons not in the toolbar (and Extensions while none is pinned), new
    /// tab and windows, zoom, the browser's own pages, page tools, more tools, Settings, Help, then
    /// Show in Toolbar (cx-d0d.81). Catalog rows the tab cannot run drop out; no engine prints yet.
    static func overflowMenu(for entry: BrowserEntry, registry: ActionRegistry, settings: SettingsController?) -> NSMenu {
        var entries: [ContextMenuEntry] = []
        if entry.chrome.offersExtensionsMenuInMore { entries.append(.action("browser.extensions.menu")) }
        for button in entry.chrome.toolbarButtons.menuButtons {
            switch button {
            case .designMode: entries.append(.action("toggleBrowserDesignMode"))
            case .devTools: entries.append(.action("toggleBrowserDeveloperTools"))
            case .profile: entries.append(.action("browser.profile.choose"))
            case .theme: entries.append(.choices("browserTheme"))
            // Zoom, Bookmark Manager and Downloads are rows of their own below.
            // The media hub only while a tab has media.
            case .media: if entry.chrome.toolbarButtons.hasContent(.media) { entries.append(.action("browser.media.show")) }
            case .zoom, .favorites, .downloads, .overflow: break
            }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries += [
            .action("newTab.default"), .action("newWindow"), .action("newIncognitoWindow"), .separator,
            .action("browserZoomOut"), .action("browserZoomIn"), .action("browserZoomReset"), .action("toggleFullScreen"), .separator,
            .action("bookmark.manager"), .action("browserShowHistory"),
            .folder(.group, [.action("tabGroup.create"), .action("tabGroup.addTab")]),
            .action("browser.downloads.show"), .action("browser.extensions.manage"), .action("passwords.open"),
            .action("history.clear"), .separator,
            .action("splitBrowserRight"), .action("browserScreenshotPage"), .action("browserScreenshotSection"), .action("find"), .separator,
            .folder(.tools, [
                .action("toggleBrowserFocusMode"), .action("palette.browserOpenDefault"),
                .action(entry.tab.engineKind == .cef ? "browser.openInWebKit" : "browser.openInChromium"), .action("importFromBrowser"),
            ]), .separator,
            .action("openSettings"), .action("help.documentation"),
        ]
        let menu = registry.makeContextMenu(for: .browserPage, target: tabTarget(entry), entries: entries)
        return entry.chrome.toolbarButtons.addingShowInToolbar(to: menu, BrowserToolbarButtonsSetting.menuToggle(settings))
    }
}
