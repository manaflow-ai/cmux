import AppKit
import CmuxNextActions
import CmuxNextBrowser
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
/// | profile | `browser.profile.choose`, the profile switcher (`profileSwitcherMenu`) |
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
            chrome.toolbarButtons.present(overflowMenu(for: entry, registry: registry, settings: context.services.settings), from: .overflow)
        })
    }

    /// Wires a new browser page's buttons (`TabContentCache.onBrowserEntryCreated`).
    static func install(on entry: BrowserEntry, services: AppServices) {
        let key = tabKey(entry)
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
        ActionTargetRef(kind: .tab, id: tabKey(entry))
    }

    /// The tab id the App keys `entry` by (`TabContentCache`): the address
    /// bar's, which an adopted page (a popup or link opened into a new tab)
    /// keeps although its own page id differs.
    private static func tabKey(_ entry: BrowserEntry) -> String {
        entry.state.tabKey ?? entry.tab.id.rawValue
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

    /// The toolbar profile button's menu: the profile switcher, then Import from Browser and this
    /// profile's own extensions (chrome://extensions and the Web Store open in it).
    static func profileMenu(for entry: BrowserEntry, services: AppServices) -> NSMenu {
        let target = tabTarget(entry)
        let extras: [ContextMenuEntry] = [.action("importFromBrowser"), .separator,
                                          .action("browser.extensions.manage"), .action("browser.extensions.webStore")]
        let menu = profileSwitcherMenu(forTab: tabKey(entry), services: services, customize: false)
        menu.addItem(.separator())
        move(services.registry.makeContextMenu(for: .browserPage, target: target, entries: extras), into: menu)
        return menu
    }

    /// Chrome's profile menu (https://github.com/manaflow-ai/cmux/issues/42438), for the omnibar avatar and the
    /// toolbar profile button: the tab's profile as the header; Other Profiles, one row each that
    /// moves the tab into it with one click (`browserProfile.moveTab`; with Option, Use for This
    /// Workspace, `browserProfile.setWorkspaceDefault`); Add, Guest (an incognito window) and Manage
    /// (Settings > Browser Profiles); then the profile's own actions (the `.browserProfile` menu:
    /// New Tab, Window and Workspace with it, Rename, Appearance, Clear Browsing Data, Delete).
    /// Every row runs a catalog action. The `tab` argument names the place, so New Tab with Browser
    /// Profile and Manage Extensions open in the tab's pane, not the focused one.
    static func profileSwitcherMenu(forTab key: String, services: AppServices, customize: Bool = true) -> NSMenu {
        let registry = services.registry
        let profiles = services.browserProfiles
        let tab = ActionTargetRef(kind: .tab, id: key)
        let current = services.cache.tabModel(key).map(profiles.profileID(ofTab:)) ?? BrowserProfileRecord.defaultID
        let menu = NSMenu()
        menu.addItem(ProfileSwitcherRows.header(profiles.badge(current)))
        let others = profiles.ordered.filter { $0.id != current }
        let workspace = services.workspaceID(ofTab: key).map { ActionTargetRef(kind: .workspace, id: $0) }
        // An incognito tab keeps its window's profile (`requireMovable`): nothing to switch to.
        if !others.isEmpty, !services.cache.browserTabs.isIncognitoTab(key) {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: BrowserProfileAppStrings.otherProfiles))
            for record in others {
                let face = ProfileBadgeView.image(profiles.badge(record.id), side: ProfileSwitcherRows.rowAvatar)
                let profile: [String: ActionValue] = ["browserProfile": .string(record.id)]
                if let row = registry.makeContextMenuItem(for: "browserProfile.moveTab", in: .browserProfile, target: tab,
                                                          arguments: profile, title: record.name) {
                    row.image = face
                    row.identifier = NSUserInterfaceItemIdentifier("browserProfile.switch.\(record.id)")
                    menu.addItem(row)
                }
                // Option: the workspace's new tabs use it (Use “Work” for This Workspace).
                let forWorkspace = profile.merging(workspace.map { ["workspace": .target($0)] } ?? [:]) { mine, _ in mine }
                if workspace != nil, let row = registry.makeContextMenuItem(for: "browserProfile.setWorkspaceDefault", in: .browserProfile,
                                                                            arguments: forWorkspace,
                                                                            title: BrowserProfileAppStrings.useForWorkspace(record.name)) {
                    row.image = face
                    row.isAlternate = true
                    row.keyEquivalentModifierMask = .option
                    menu.addItem(row)
                }
            }
        }
        menu.addItem(.separator())
        let rows: [(ActionID, String, String, [String: ActionValue])] = [
            ("browserProfile.new", BrowserProfileAppStrings.addProfile, "plus", [:]),
            ("newIncognitoWindow", BrowserProfileAppStrings.guestWindow, "person.crop.circle", [:]),
            ("openSettings", BrowserProfileAppStrings.manageProfiles, "gearshape", ["setting": .string("card.browserProfiles")]),
        ]
        for (id, title, symbol, arguments) in rows {
            guard let row = registry.makeContextMenuItem(for: id, in: .browserProfile, arguments: arguments, title: title) else { continue }
            row.image = ProfileSwitcherRows.symbol(symbol, label: title)
            menu.addItem(row)
        }
        menu.addItem(.separator())
        // The profile's own actions below, as the badge's menu had them; Add above stands for New Browser Profile.
        let own = registry.makeContextMenu(for: .browserProfile, target: ActionTargetRef(kind: .browserProfile, id: current),
                                           entries: registry.contextMenuEntries(for: .browserProfile, removing: ["browserProfile.new"]),
                                           arguments: ["tab": .target(tab)], customize: customize)
        move(own, into: menu)
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
        let buttons = entry.chrome?.toolbarButtons
        if entry.chrome?.offersExtensionsMenuInMore == true { entries.append(.action("browser.extensions.menu")) }
        for button in buttons?.menuButtons ?? [] {
            switch button {
            case .designMode: entries.append(.action("toggleBrowserDesignMode"))
            case .devTools: entries.append(.action("toggleBrowserDeveloperTools"))
            case .profile: entries.append(.action("browser.profile.choose"))
            case .theme: entries.append(.choices("browserTheme"))
            // Zoom, Bookmark Manager and Downloads are rows of their own below.
            // The media hub only while a tab has media.
            case .media: if buttons?.hasContent(.media) == true { entries.append(.action("browser.media.show")) }
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
        return buttons?.addingShowInToolbar(to: menu, BrowserToolbarButtonsSetting.menuToggle(settings)) ?? menu
    }
}

/// The profile switcher's own rows: its header (the tab's profile, its avatar, name and
/// "Current profile", as Chrome's profile menu opens) and the symbols of Add, Guest and Manage.
@MainActor enum ProfileSwitcherRows {
    static var rowAvatar: CGFloat { NSFont.menuFont(ofSize: 0).pointSize + 5 }
    static var headerAvatar: CGFloat { TypeScale.title * 2 }

    static func header(_ badge: BrowserProfileBadge) -> NSMenuItem {
        let item = NSMenuItem(title: badge.name, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("browserProfile.switcher.current")
        let avatar = NSImageView(image: ProfileBadgeView.image(badge, side: headerAvatar))
        let name = NSTextField(labelWithString: badge.name)
        name.font = .systemFont(ofSize: TypeScale.body, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let caption = NSTextField(labelWithString: BrowserProfileAppStrings.currentProfile)
        caption.font = .systemFont(ofSize: TypeScale.detail)
        caption.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, caption])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [avatar, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("\(badge.name), \(BrowserProfileAppStrings.currentProfile)")
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: headerAvatar),
            avatar.heightAnchor.constraint(equalToConstant: headerAvatar),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        row.frame.size = row.fittingSize
        item.view = row
        return item
    }

    /// A template at the menu font's size, as the other menus' rows (`MenuBarMenuBuilder`).
    static func symbol(_ name: String, label: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}
