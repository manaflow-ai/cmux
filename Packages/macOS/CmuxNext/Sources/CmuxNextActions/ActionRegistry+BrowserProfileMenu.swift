public import AppKit

extension ActionRegistry {
    /// The browser toolbar's profile button menu for the tab `tabKey` (https://github.com/manaflow-ai/cmux/issues/42437),
    /// in the order of cmuxterm-hq RFD 0050, D2:
    ///
    /// 1. the tab's own profile (`current`): with `header`, one row of its avatar (`image`), its name (`title`) and why the
    ///    tab has it (`subtitle`, `BrowserProfileBadge.menuHeader`); without, its checked row among the others. It runs nothing.
    /// 2. one row per other profile in `profiles` (`id`, shown `title`), moving the tab with `browserProfile.moveTab`. With
    ///    `workspace`, holding Option turns the row into "Use … for This Workspace" (`browserProfile.setWorkspaceDefault`).
    /// 3. New Browser Profile and New Incognito Window.
    /// 4. the tab's profile's own menu as the catalog places it (New Tab, Window and Workspace with it, Rename, Appearance,
    ///    Manage Extensions, Clear Browsing Data, Delete), unless `profileActions` is false (an incognito tab's data is no
    ///    profile's).
    /// 5. Import from Browser, the Web Store, and Manage Browser Profiles (Settings, on the profiles card).
    ///
    /// Every row is a palette action (`MenuPaletteParityTests`).
    public func makeBrowserProfileMenu(tabKey: String, current: String, profiles: [(id: String, title: String)],
                                       profileActions: Bool = true,
                                       header: (title: String, subtitle: String?, image: NSImage?)? = nil,
                                       workspace: String? = nil) -> NSMenu {
        let target = ActionTargetRef(kind: .tab, id: tabKey)
        let menu = NSMenu()
        if let header {
            let item = NSMenuItem(title: header.title, action: nil, keyEquivalent: "")
            item.image = header.image
            if #available(macOS 14.4, *) { item.subtitle = header.subtitle }
            item.isEnabled = false
            item.identifier = Self.browserProfileHeaderID
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for profile in profiles {
            guard profile.id != current else {
                guard header == nil else { continue }
                let item = NSMenuItem(title: profile.title, action: nil, keyEquivalent: "")
                item.state = .on
                menu.addItem(item)
                continue
            }
            guard let item = makeContextMenuItem(for: "browserProfile.moveTab", in: .browserPage, target: target,
                                                 arguments: ["browserProfile": .string(profile.id)], title: profile.title) else { continue }
            menu.addItem(item)
            // Option: the workspace's profile, for the tabs made in it from now on (this tab keeps its own).
            if let workspace,
               let alternate = makeContextMenuItem(for: "browserProfile.setWorkspaceDefault", in: .browserPage,
                                                   target: ActionTargetRef(kind: .workspace, id: workspace),
                                                   arguments: ["browserProfile": .string(profile.id)],
                                                   title: Self.browserProfileUseForWorkspace(profile.title)) {
                alternate.isAlternate = true
                alternate.keyEquivalentModifierMask = .option
                menu.addItem(alternate)
            }
        }
        var parts: [NSMenu] = []
        // New Browser Profile is a row of the profile's own menu too; here it leads, beside New Incognito Window.
        parts.append(makeContextMenu(for: .browserPage, target: target, entries: [.action("browserProfile.new"), .action("newIncognitoWindow")]))
        if profileActions {
            let own = makeContextMenu(for: .browserProfile, target: ActionTargetRef(kind: .browserProfile, id: current),
                                      arguments: ["tab": .target(target)], customize: false)
            for item in own.items where Self.menuRun(of: item)?.id == "browserProfile.new" { own.removeItem(item) }
            parts.append(own)
        }
        // Without the profile's rows (an incognito tab) the tab's extensions stay, as a page row: it touches no
        // profile's data.
        let page: [ContextMenuEntry] = [.action("importFromBrowser")]
            + (profileActions ? [] : [.action("browser.extensions.manage")]) + [.action("browser.extensions.webStore")]
        parts.append(makeContextMenu(for: .browserPage, target: target, entries: page))
        for part in parts where !part.items.isEmpty {
            if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            for item in part.items {
                part.removeItem(item)
                menu.addItem(item)
            }
        }
        if let manage = makeContextMenuItem(for: "openSettings", in: .browserPage,
                                            arguments: ["section": .string("rooms"), "setting": .string("card.browserProfiles")],
                                            title: Self.browserProfileManage) {
            menu.addItem(manage)
        }
        // No separator pair, and none first or last (a part whose first or last row an administrator turned off).
        for item in menu.items.reversed() where item.isSeparatorItem {
            let index = menu.index(of: item)
            if index == 0 || index == menu.items.count - 1 || menu.items[index - 1].isSeparatorItem { menu.removeItem(item) }
        }
        return menu
    }

    /// The header row's identifier (tests, UI automation).
    public static let browserProfileHeaderID = NSUserInterfaceItemIdentifier("browser.profileMenu.header")

    static func browserProfileUseForWorkspace(_ name: String) -> String {
        String(format: String(localized: "menu.browserProfile.useForWorkspace", defaultValue: "Use %@ for This Workspace",
                              table: "BrowserProfileActions", bundle: .localizedModule), name)
    }

    static var browserProfileManage: String {
        String(localized: "menu.browserProfile.manage", defaultValue: "Manage Browser Profiles…",
               table: "BrowserProfileActions", bundle: .localizedModule)
    }
}
