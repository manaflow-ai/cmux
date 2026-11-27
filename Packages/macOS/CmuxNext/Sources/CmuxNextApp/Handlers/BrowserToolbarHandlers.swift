import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextDaemonService
import CmuxNextDesign
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
/// | profile | `browser.profile.choose`, the profile menu (`ActionRegistry.makeBrowserProfileMenu`) |
/// | theme | a menu of `browserTheme` system, light, dark |
/// | DevTools | `toggleBrowserDeveloperTools` |
/// | More | `browser.overflow.menu` |
/// | Publish | the Publish popover (`BrowserPublishPopover`), on a Cloud preview with `experiments.appsTier` on |
enum BrowserToolbarHandlers {
    /// The action a press runs (`BrowserToolbarButton.actionName`).
    static func actionID(for button: BrowserToolbarButton) -> ActionID { ActionID(rawValue: button.actionName) }

    /// The `theme` argument of `browserTheme`; a missing or unknown
    /// value follows the app.
    static func colorScheme(_ invocation: ActionInvocation) -> BrowserColorScheme {
        invocation["theme"]?.stringValue.flatMap(BrowserColorScheme.init(rawValue:)) ?? .system
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browser.profile.choose", run: { invocation in
            let (entry, chrome) = try context.shownPage(invocation)
            chrome.toolbarButtons.present(profileMenu(forTab: entry.key, services: context.services), from: .profile)
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
            press(button, entry: entry, services: services)
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
            buttons.publishable = { [weak services] url, title in
                services.map { publisher(url: url, title: title, services: $0) != nil } ?? false
            }
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

    static func press(_ button: BrowserToolbarButton, entry: BrowserEntry, services: AppServices) {
        let registry = services.registry
        let target = tabTarget(entry)
        if button == .theme {
            return entry.chrome?.toolbarButtons.present(themeMenu(target: target, registry: registry), from: .theme) ?? ()
        }
        if button == .publish { return showPublish(for: entry, services: services) }
        registry.perform(actionID(for: button), invocation: ActionInvocation(target: target, origin: .user))
    }

    /// The page's publish (``AppsTierPublisher``): a Cloud preview this app opened, with `experiments.appsTier` on.
    static func publisher(url: URL?, title: String?, services: AppServices) -> AppsTierPublisher? {
        url.flatMap { AppsTierPublisher(enabled: services.settings?.snapshot.experimentSwitches["appsTier"] == true, url: $0,
                                        title: title, previews: services.appsTierPreviews.previews) }
    }

    /// Opens (or closes) the Publish popover under `entry`'s Publish button; Open shows the app in a new tab.
    static func showPublish(for entry: BrowserEntry, services: AppServices) {
        guard let popover = entry.chrome?.toolbarButtons.publishPopover else { return }
        if popover.isShown { return popover.close() }
        guard let page = publisher(url: entry.tab.state.url, title: entry.tab.state.title, services: services) else { return }
        popover.toggle(BrowserPublishSource(
            suggestedName: page.target.suggestedName,
            form: page.form(name:team:),
            publish: { [weak services] name, team in
                guard let services else { return .unreachable(CancellationError().localizedDescription) }
                let api = services.cloud.machineAPI
                let answer = await page.publish(name: name, team: team, exec: { try await api.exec($0, command: $1, timeoutMs: $2) })
                if case .published = answer { services.appsTierPreviews.published() } // the sidebar's Apps section reads again
                return answer
            },
            open: { [weak services] url in
                guard let services, let pane = services.windows.active?.focusedPane?.pane else { return }
                // task-owner: one tab opening after the popover closed; its failure leaves the link in the popover's answer.
                Task { _ = try? await services.cache.browserTabs.open(BrowserEngineChoice(engine: .cef, pinned: true), in: pane,
                                                                      url: url.absoluteString, activate: true) }
            }))
    }

    /// The sidebar's `+ Publish preview…` row: the focused pane's page's Publish; false when it has none.
    static func publishFocused(_ services: AppServices) -> Bool {
        guard let entry = try? AppActionContext(services: services).page(ActionInvocation(arguments: [:], origin: .user)),
              publisher(url: entry.tab.state.url, title: entry.tab.state.title, services: services) != nil else { return false }
        showPublish(for: entry, services: services)
        return true
    }

    static func profileName(forTab key: String, services: AppServices) -> String {
        services.browserProfiles.toolbarBadge(forTab: key).name // an incognito tab's says Incognito, as its disc
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

    /// The profile button's menu (`ActionRegistry.makeBrowserProfileMenu`), for the tab by the key the App keeps it under: an
    /// adopted page's own id finds no tab, and Clear Browsing Data or Delete would act on Default. The look `style` (the debug
    /// object menu's), else `card` while Settings > Experiments > Browser Profile Card is on; off (the default), cmux#51248's.
    static func profileMenu(forTab key: String, services: AppServices, style: BrowserProfileMenuStyle? = nil) -> NSMenu {
        let style = style ?? (DesignSettings.shared.experiment("browserProfileCard") ? .card : nil)
        let profiles = services.browserProfiles
        let current = services.cache.tabModel(key).map(profiles.profileID(ofTab:)) ?? BrowserProfileRecord.defaultID
        let incognito = services.cache.browserTabs.isIncognitoTab(key)
        let workspace = services.workspaceID(ofTab: key)
        // The header: the tab's profile as the button draws it and why the tab has it (incognito: when its data goes).
        let header = profiles.toolbarBadge(forTab: key).menuHeader(BrowserProfileCascade.source(
            tabProfile: current, workspace: profiles.workspaceDefault(workspace), room: profiles.roomDefault(workspace), known: profiles.isKnown))
        return services.registry.makeBrowserProfileMenu(
            tabKey: key, current: current,
            profiles: profiles.ordered.map { record in (record.id, style != nil ? record.name : record.icon.map { "\($0)  \(record.name)" } ?? record.name) },
            profileActions: !incognito, header: header, workspace: incognito ? nil : workspace, style: style ?? .list,
            account: style == nil ? nil : services.menuBarAccount.map { ($0.lines.last ?? "", services.menuBarAvatar) },
            images: style == nil ? [:] : BrowserProfileBadge.menuImages(profiles.ordered))
    }

    /// The More menu (cx-6qwm, `ActionRegistry.makeBrowserMoreMenu`) on glass, as ChatGPT Atlas's: the hidden toolbar
    /// buttons (and Extensions while none is pinned) and Show in Toolbar (cx-d0d.81) in Tools; no Design Mode row.
    static func overflowMenu(for entry: BrowserEntry, registry: ActionRegistry, settings: SettingsController?) -> NSMenu {
        var entries: [ContextMenuEntry] = []
        let buttons = entry.chrome?.toolbarButtons
        if entry.chrome?.offersExtensionsMenuInMore == true { entries.append(.action("browser.extensions.menu")) }
        for button in buttons?.menuButtons ?? [] {
            switch button {
            case .devTools: entries.append(.action("toggleBrowserDeveloperTools"))
            case .profile: entries.append(.action("browser.profile.choose"))
            case .theme: entries.append(.choices("browserTheme"))
            // Zoom is the zoom row; Bookmark Manager and Downloads are rows of their own.
            // The media hub only while a tab has media.
            case .media: if buttons?.hasContent(.media) == true { entries.append(.action("browser.media.show")) }
            case .publish, .designMode, .zoom, .favorites, .downloads, .overflow: break
            }
        }
        // Show in Toolbar's rows run the palette's Pin or Unpin Browser Toolbar Button… (one handler).
        let pin = BrowserToolbarButtonsSetting.menuToggle(settings)
        let show = buttons?.showInToolbarItem(enabled: pin.enabled) { [weak registry] in runToolbarPin($0.rawValue, registry: registry, fallback: pin.toggle) }
        return registry.makeBrowserMoreMenu(tabKey: entry.key, buttons: entries, chromium: entry.tab.engineKind == .cef,
                                            toolsFooter: show.map { [$0] } ?? []) { buttons?.zoomRow($0) }
    }
}

/// Palette rows of hand-built browser and tab bar menus (also `browser.toolbar.togglePin`, the More menu's Show in
/// Toolbar rows, and `tabs.toolbar.togglePin`, the palette's Pin or Unpin Tab Bar Button…), which run these actions
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
