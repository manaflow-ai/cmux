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
        BrowserDownloadsMenu.bind(into: registry, list: context.services.cache.pageRequests.downloads)
        bindTogglePin(into: registry, settings: { [weak services = context.services] in services?.settings })
        registry.bind("browser.profile.choose", run: { invocation in
            let (entry, chrome) = try context.shownPage(invocation)
            chrome.toolbarButtons.present(profileMenu(for: entry, services: context.services), from: .profile)
        })
        registry.bind("browser.media.show", run: { invocation in
            let (_, chrome) = try context.shownPage(invocation)
            chrome.toolbarButtons.present(BrowserMediaMenu.menu(context.services, rows: chrome.toolbarButtons.mediaRows), from: .media)
        })
        registry.bind("browser.downloads.show", run: { invocation in
            let entry = try context.page(invocation)
            showDownloads(for: entry, services: context.services, finished: false)
        })
        registry.bind("browser.overflow.menu", run: { invocation in
            let (entry, chrome) = try context.shownPage(invocation)
            chrome.toolbarButtons.presentGlass(overflowMenu(for: entry, registry: registry, settings: context.services.settings), from: .overflow)
        })
    }

    /// Wires a new browser page's buttons (`TabContentCache.onBrowserEntryCreated`).
    static func install(on entry: BrowserEntry, services: AppServices) {
        let key = entry.key
        entry.state.onToolbarPress = { [weak services, weak entry] button in
            guard let services, let entry else { return }
            press(button, entry: entry, registry: services.registry)
        }
        entry.state.configureToolbar = { [weak services] buttons in
            buttons.shortcutHint = { [weak services] button in
                guard [.media, .zoom, .favorites, .downloads, .designMode, .devTools].contains(button) else { return nil }
                return services?.registry.shortcutDisplay(for: actionID(for: button))
            }
            buttons.downloads = { [weak services] in
                services?.cache.pageRequests.downloads.toolbarSummary(forTab: key) ?? BrowserToolbarDownloads()
            }
            buttons.media = { [weak services] in services.map { $0.cache.pageRequests.media.toolbar(in: $0.cache) } ?? BrowserToolbarMedia() }
            buttons.pins = { [weak services] in services?.settings.map(BrowserToolbarButtonsSetting.current)?.pinned ?? BrowserToolbarButtonsSetting.fallback }
        }
        entry.state.profileName = profileName(forTab: key, services: services)
        // The omnibar's "Focus Mode" badge leaves focus mode (the action's one path).
        entry.state.onFocusModeBadgePress = { [weak services, weak entry] in
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
        guard let buttons = entry.chrome?.toolbarButtons else { return false }
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

    /// Show in Toolbar (`browser.toolbar.togglePin`): pins or unpins `button` in cmux.json; the
    /// palette lists the pinnable buttons by their Show in Toolbar titles (`browserToolbarButtons`).
    static func bindTogglePin(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?) {
        let previous = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.browserToolbarButtons else { return previous?(source) ?? [] }
            return BrowserToolbarButton.pinnable.map { ActionEnumCase(value: $0.rawValue, title: $0.pinTitle) }
        }
        let managed = { settings().map(BrowserToolbarButtonsSetting.isManaged(in:)) ?? false }
        registry.bindEffect("browser.toolbar.togglePin", requires: nil, unavailable: { managed() ? RefusalStrings.turnedOffByOrganization : nil }, effect: { invocation in
            let text = invocation["button"]?.stringValue ?? ""
            guard let button = BrowserToolbarButton.pinnable.first(where: { $0.rawValue == text || $0.pinTitle == text }), let settings = settings() else {
                throw ActionFailure.notFound(RefusalStrings.noToolbarButton)
            }
            BrowserToolbarButtonsSetting.toggle(button.rawValue, in: settings)
            return .done
        })
    }

    static func press(_ button: BrowserToolbarButton, entry: BrowserEntry, registry: ActionRegistry) {
        let target = tabTarget(entry)
        if button == .theme {
            return entry.chrome?.toolbarButtons.present(themeMenu(target: target, registry: registry), from: .theme) ?? ()
        }
        registry.perform(actionID(for: button), invocation: ActionInvocation(target: target, origin: .user))
    }

    static func profileName(forTab key: String, services: AppServices) -> String {
        services.browserProfiles.displayName(services.cache.tabModel(key).map(services.browserProfiles.profileID(ofTab:)))
    }

    private static func tabTarget(_ entry: BrowserEntry) -> ActionTargetRef {
        ActionTargetRef(kind: .tab, id: entry.key)
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

    /// The profile button's menu (`ActionRegistry.makeBrowserProfileMenu`), for the tab by the key the App keeps it
    /// under: an adopted page's own id finds no tab, and Clear Browsing Data or Delete would act on Default.
    static func profileMenu(for entry: BrowserEntry, services: AppServices) -> NSMenu {
        let profiles = services.browserProfiles
        let key = entry.key
        return services.registry.makeBrowserProfileMenu(
            tabKey: key, current: services.cache.tabModel(key).map(profiles.profileID(ofTab:)) ?? BrowserProfileRecord.defaultID,
            profiles: profiles.ordered.map { record in (record.id, record.icon.map { "\($0)  \(record.name)" } ?? record.name) },
            profileActions: !services.cache.browserTabs.isIncognitoTab(key))
    }

    /// The More menu (cx-6qwm, `ActionRegistry.makeBrowserMoreMenu`) on glass: the hidden toolbar buttons (and
    /// Extensions while none is pinned) first, the toolbar's zoom row, then Show in Toolbar (cx-d0d.81).
    static func overflowMenu(for entry: BrowserEntry, registry: ActionRegistry, settings: SettingsController?) -> NSMenu {
        var entries: [ContextMenuEntry] = []
        let buttons = entry.chrome?.toolbarButtons
        if entry.chrome?.offersExtensionsMenuInMore == true { entries.append(.action("browser.extensions.menu")) }
        for button in buttons?.menuButtons ?? [] {
            switch button {
            case .designMode: entries.append(.action("toggleBrowserDesignMode"))
            case .devTools: entries.append(.action("toggleBrowserDeveloperTools"))
            case .profile: entries.append(.action("browser.profile.choose"))
            case .theme: entries.append(.choices("browserTheme"))
            // Zoom is the zoom row; Bookmark Manager and Downloads are rows of their own.
            // The media hub only while a tab has media.
            case .media: if buttons?.hasContent(.media) == true { entries.append(.action("browser.media.show")) }
            case .zoom, .favorites, .downloads, .overflow: break
            }
        }
        let menu = registry.makeBrowserMoreMenu(tabKey: entry.key, buttons: entries, chromium: entry.tab.engineKind == .cef) { buttons?.zoomRow($0) }
        // Show in Toolbar's rows run `browser.toolbar.togglePin`, the palette's row.
        let pin = (enabled: settings.map { !BrowserToolbarButtonsSetting.isManaged(in: $0) } ?? false, toggle: { [weak registry] (id: String) in
            _ = registry?.perform("browser.toolbar.togglePin", invocation: ActionInvocation(arguments: ["button": .string(id)], origin: .user))
        })
        return buttons?.addingShowInToolbar(to: menu, pin) ?? menu
    }
}
