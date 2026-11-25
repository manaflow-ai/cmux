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
        if finished { return BrowserDownloadsPopup.shared.showFinished(list, registry: services.registry, buttons: buttons, showFolder: showFolder) }
        BrowserDownloadsPopup.shared.toggle(list, registry: services.registry, buttons: buttons, showFolder: showFolder)
        return true
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
        // Show in Toolbar's rows run the palette's Pin or Unpin Browser Toolbar Button… (one handler).
        let pin = BrowserToolbarButtonsSetting.menuToggle(settings)
        return buttons?.addingShowInToolbar(to: menu, (pin.enabled, { [weak registry] id in runToolbarPin(id, registry: registry, fallback: pin.toggle) })) ?? menu
    }
}

/// Palette rows of hand-built browser and tab bar menus (also `browser.toolbar.togglePin`, the More menu's Show in
/// Toolbar rows, and `tabs.toolbar.togglePin`, the tab bar "…" menu's Show in Tab Bar rows), which run these actions
/// themselves so the menu and
/// the palette run one handler:
/// - `browser.goToHistoryEntry` (`entry`: the offset from the current page): a row of the Back and
///   Forward buttons' entry menus (`BrowserChromeView.goToBackForwardEntry`, through
///   `BrowserTabIntent.goToHistoryEntry`); the palette lists the focused tab's entries
///   (`browserBackForwardEntries`).
/// - `browser.download.*` (`download`: the download's id): the rows of a download's menu in the
///   Downloads popup (``BrowserDownloadsMenu``); the palette lists the downloads, newest first (`browserDownloads`).
extension BrowserToolbarHandlers {
    static let downloadActions: [ActionID] = [
        "browser.download.open", "browser.download.reveal", "browser.download.togglePause",
        "browser.download.retry", "browser.download.cancel", "browser.download.copyLink",
    ]

    static func bindMenuRows(into registry: ActionRegistry, context: AppActionContext) {
        bindDownloads(into: registry, list: { context.services.cache.pageRequests.downloads })
        bindBackForward(into: registry, page: { BrowserHitHandlers.page($0, context) })
        bindToolbarPin(into: registry, settings: { [weak services = context.services] in services?.settings })
        PaneToolbar.bindTogglePin(into: registry, settings: { [weak services = context.services] in services?.settings })
    }

    /// Pin or Unpin Browser Toolbar Button… (`button`: a ``BrowserToolbarButton`` id): the More menu's Show in Toolbar
    /// rows run it (``overflowMenu(for:registry:settings:)``). The palette lists the pinnable buttons, the pinned ones
    /// marked (`browserToolbarButtons`), and offers it while the list is the person's (not managed), as the rows are enabled.
    static func bindToolbarPin(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?) {
        registry.bindEffect("browser.toolbar.togglePin", isEnabled: {
            settings().map { !BrowserToolbarButtonsSetting.isManaged(in: $0) } ?? false
        }, effect: { invocation in
            guard let settings = settings(),
                  let button = invocation["button"]?.stringValue.flatMap(BrowserToolbarButton.init(rawValue:)), button.isPinnable else { return .done }
            BrowserToolbarButtonsSetting.toggle(button.rawValue, in: settings)
            return .done
        })
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.browserToolbarButtons else { return other?(source) ?? [] }
            let pinned = settings().map { BrowserToolbarButtonsSetting.current($0).pinned } ?? []
            return BrowserToolbarButton.pinnable.map { button in
                ActionEnumCase(value: button.rawValue, title: button.pinTitle, symbol: pinned.contains(button.rawValue) ? "pin.fill" : "pin")
            }
        }
    }

    /// A Show in Toolbar row: the palette's Pin or Unpin Browser Toolbar Button… on `button`; where it does not run
    /// (no registry, the list is managed), the row's own toggle, as before.
    static func runToolbarPin(_ button: String, registry: ActionRegistry?, fallback: (String) -> Void) {
        let invocation = ActionInvocation(arguments: ["button": .string(button)], origin: .user)
        if registry?.perform("browser.toolbar.togglePin", invocation: invocation) != true { fallback(button) }
    }

    /// The downloads rows over `list` (the App's one downloads list). The palette offers them while it lists a download.
    static func bindDownloads(into registry: ActionRegistry, list: @escaping @MainActor () -> BrowserDownloadList) {
        for id in downloadActions {
            registry.bindEffect(id, isEnabled: { !list().items.isEmpty }, effect: { invocation in
                let downloads = list()
                let wanted = invocation["download"]?.stringValue
                guard let download = downloads.items.first(where: { $0.id.uuidString == wanted }),
                      BrowserDownloadsMenu.perform(id, on: download, list: downloads) else {
                    return .refused(BrowserHitStrings.downloadUnavailable)
                }
                return .done
            })
        }
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.browserDownloads else { return other?(source) ?? [] }
            return list().items.reversed().map { ActionEnumCase(value: $0.id.uuidString, title: $0.filename, subtitle: BrowserDownloadsMenu.status($0)) }
        }
    }

    /// Go Back or Forward to… on `page(invocation)` (the invocation's tab, else the focused one).
    static func bindBackForward(into registry: ActionRegistry, page: @escaping @MainActor (ActionInvocation) -> (any BrowserTab)?) {
        let listing = { @MainActor (invocation: ActionInvocation) -> (any BrowserBackForwardListing)? in
            page(invocation) as? any BrowserBackForwardListing
        }
        registry.bindEffect("browser.goToHistoryEntry", effect: { invocation in
            guard let tab = listing(invocation), let list = tab.navigationList() else { return .refused(MiscHandlerStrings.noBrowser) }
            // The offset is typed text: an addition that overflows (Int.max past a nonzero current) is no entry, not a trap.
            guard let offset = invocation["entry"]?.stringValue.flatMap({ Int($0) }), offset != 0,
                  case let (index, overflow) = list.current.addingReportingOverflow(offset), !overflow,
                  list.entries.indices.contains(index) else {
                return .refused(BrowserHitStrings.historyNoEntry)
            }
            tab.goToEntry(offset: offset)
            return .done
        })
        // Left out where the tab has no earlier or later page (the menus show only then).
        ActionTargetVisibility.gate("browser.goToHistoryEntry", in: registry) { invocation in
            guard let list = listing(invocation)?.navigationList() else { return MiscHandlerStrings.noBrowser }
            return list.back.isEmpty && list.forward.isEmpty ? BrowserHitStrings.historyNoEntry : nil
        }
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.browserBackForwardEntries else { return other?(source) ?? [] }
            guard let list = listing(ActionInvocation())?.navigationList() else { return [] }
            return (list.back + list.forward).map { row in
                ActionEnumCase(value: String(row.offset), title: row.entry.menuTitle, subtitle: row.entry.url?.absoluteString)
            }
        }
    }
}
