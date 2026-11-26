public import AppKit

/// How the browser toolbar's profile menu opens (Leo 2026-11-25, of Helium's toolbar profile menu: "yeah even helium
/// has a profile..."; "just... improve hte browser omnibar situation, obviously"). Every look holds the same rows; they
/// differ in how the tab's profile leads and how much shows at once. The variants are shown side by side in the pull
/// request that added them (cmux#55597). `card` is the one Settings > Experiments > Browser Profile Card opens; with
/// it off the app opens `list` without the account row or the avatars, cmux#51248's menu.
public nonisolated enum BrowserProfileMenuStyle: String, CaseIterable, Sendable {
    /// Helium's and Chrome's: a card with the profile's large avatar and name; the other profiles; New Browser Profile,
    /// New Incognito Window and Manage Browser Profiles together; the profile's own actions folded into Customize
    /// Profile; Import from Browser and the Web Store last.
    case card
    /// The card, then every row flat, Manage Browser Profiles last (cmux#51248's order under the card).
    case cardFlat
    /// No card: the profile as the first row (its small avatar, name and why the tab has it), every row flat.
    case list
}

extension ActionRegistry {
    /// The browser toolbar's profile button menu for the tab `tabKey` (https://github.com/manaflow-ai/cmux/issues/42437),
    /// in the order of cmuxterm-hq RFD 0050, D2, as `style` lays it out (``BrowserProfileMenuStyle``):
    ///
    /// 1. the tab's own profile (`current`): with `header`, its card (its avatar `image`, its name `title` and why the
    ///    tab has it, `subtitle`, `BrowserProfileBadge.menuHeader`), or in `list` one row of the three; without, its
    ///    checked row among the others. It runs nothing.
    /// 2. with `account` (who is signed in to cmux, their picture), one quiet row "Signed in as …" opening Accounts.
    /// 3. one row per other profile in `profiles` (`id`, shown `title`, its avatar from `images`), moving the tab with
    ///    `browserProfile.moveTab`. With `workspace`, holding Option turns the row into "Use … for This Workspace"
    ///    (`browserProfile.setWorkspaceDefault`).
    /// 4. New Browser Profile and New Incognito Window (in `card`, with Manage Browser Profiles).
    /// 5. the tab's profile's own menu as the catalog places it (New Tab, Window and Workspace with it, Rename,
    ///    Appearance, Manage Extensions, Clear Browsing Data, Delete), in `card` folded into Customize Profile, unless
    ///    `profileActions` is false (an incognito tab's data is no profile's).
    /// 6. Import from Browser and the Web Store, then (but in `card`) Manage Browser Profiles (Settings, on the profiles
    ///    card).
    ///
    /// Every row is a palette action (`MenuPaletteParityTests`).
    public func makeBrowserProfileMenu(tabKey: String, current: String, profiles: [(id: String, title: String)],
                                       profileActions: Bool = true,
                                       header: (title: String, subtitle: String?, image: NSImage?)? = nil,
                                       workspace: String? = nil, style: BrowserProfileMenuStyle = .card,
                                       account: (name: String, image: NSImage?)? = nil,
                                       images: [String: NSImage] = [:]) -> NSMenu {
        let target = ActionTargetRef(kind: .tab, id: tabKey)
        let menu = NSMenu()
        if let header {
            let item = NSMenuItem(title: header.title, action: nil, keyEquivalent: "")
            item.image = header.image
            if #available(macOS 14.4, *) { item.subtitle = header.subtitle }
            // The card draws the three larger; the row's own image and subtitle stay for VoiceOver and the tests.
            if style != .list { item.view = MenuProfileCardView(title: header.title, subtitle: header.subtitle, image: header.image) }
            item.isEnabled = false
            item.identifier = Self.browserProfileHeaderID
            menu.addItem(item)
        }
        if let account, let item = makeContextMenuItem(for: "accounts.show", in: .browserPage,
                                                       title: Self.browserProfileSignedInAs(account.name)) {
            item.image = account.image
            item.identifier = Self.browserProfileAccountID
            if style != .list, header != nil {
                // Under the card, as the line under Chrome's: no separator between them.
                menu.addItem(item)
            } else {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(item)
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for profile in profiles {
            guard profile.id != current else {
                guard header == nil else { continue }
                let item = NSMenuItem(title: profile.title, action: nil, keyEquivalent: "")
                item.state = .on
                item.image = images[profile.id]
                menu.addItem(item)
                continue
            }
            guard let item = makeContextMenuItem(for: "browserProfile.moveTab", in: .browserPage, target: target,
                                                 arguments: ["browserProfile": .string(profile.id)], title: profile.title) else { continue }
            if let image = images[profile.id] { item.image = image }
            menu.addItem(item)
            // Option: the workspace's profile, for the tabs made in it from now on (this tab keeps its own).
            if let workspace,
               let alternate = makeContextMenuItem(for: "browserProfile.setWorkspaceDefault", in: .browserPage,
                                                   target: ActionTargetRef(kind: .workspace, id: workspace),
                                                   arguments: ["browserProfile": .string(profile.id)],
                                                   title: Self.browserProfileUseForWorkspace(profile.title)) {
                alternate.isAlternate = true
                alternate.keyEquivalentModifierMask = .option
                if let image = images[profile.id] { alternate.image = image }
                menu.addItem(alternate)
            }
        }
        let manage = makeContextMenuItem(for: "openSettings", in: .browserPage,
                                         arguments: ["section": .string("rooms"), "setting": .string("card.browserProfiles")],
                                         title: Self.browserProfileManage)
        if style == .card { manage?.image = rowIcon("person.2.badge.gearshape") }
        var parts: [[NSMenuItem]] = []
        // New Browser Profile is a row of the profile's own menu too; here it leads, beside New Incognito Window.
        var creation = makeContextMenu(for: .browserPage, target: target, entries: [.action("browserProfile.new"), .action("newIncognitoWindow")])
            .itemsRemoved()
        if style == .card, let manage { creation.append(manage) }
        parts.append(creation)
        if profileActions {
            let own = makeContextMenu(for: .browserProfile, target: ActionTargetRef(kind: .browserProfile, id: current),
                                      arguments: ["tab": .target(target)], customize: false)
            for item in own.items where Self.menuRun(of: item)?.id == "browserProfile.new" { own.removeItem(item) }
            if style == .card {
                // Helium's Customize Profile: the profile's own rows one level down, so the menu stays short.
                let rows = own.itemsRemoved()
                if rows.contains(where: { !$0.isSeparatorItem }) {
                    let customize = NSMenuItem(title: Self.browserProfileCustomize, action: nil, keyEquivalent: "")
                    customize.image = rowIcon("pencil")
                    customize.identifier = Self.browserProfileCustomizeID
                    let submenu = NSMenu(title: customize.title)
                    rows.forEach(submenu.addItem)
                    Self.dropStraySeparators(submenu)
                    customize.submenu = submenu
                    parts.append([customize])
                }
            } else {
                parts.append(own.itemsRemoved())
            }
        }
        // Without the profile's rows (an incognito tab) the tab's extensions stay, as a page row: it touches no
        // profile's data.
        let page: [ContextMenuEntry] = [.action("importFromBrowser")]
            + (profileActions ? [] : [.action("browser.extensions.manage")]) + [.action("browser.extensions.webStore")]
        parts.append(makeContextMenu(for: .browserPage, target: target, entries: page).itemsRemoved())
        for part in parts where !part.isEmpty {
            if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            part.forEach(menu.addItem)
        }
        if style != .card, let manage { menu.addItem(manage) }
        Self.dropStraySeparators(menu)
        return menu
    }

    /// No separator pair, and none first or last (a part whose first or last row an administrator turned off).
    private static func dropStraySeparators(_ menu: NSMenu) {
        for item in menu.items.reversed() where item.isSeparatorItem {
            let index = menu.index(of: item)
            if index == 0 || index == menu.items.count - 1 || menu.items[index - 1].isSeparatorItem { menu.removeItem(item) }
        }
    }

    /// The header row's identifier (tests, UI automation).
    public static let browserProfileHeaderID = NSUserInterfaceItemIdentifier("browser.profileMenu.header")
    /// The "Signed in as …" row's identifier.
    public static let browserProfileAccountID = NSUserInterfaceItemIdentifier("browser.profileMenu.account")
    /// The Customize Profile row's identifier (the `card` look).
    public static let browserProfileCustomizeID = NSUserInterfaceItemIdentifier("browser.profileMenu.customize")

    static func browserProfileUseForWorkspace(_ name: String) -> String {
        String(format: String(localized: "menu.browserProfile.useForWorkspace", defaultValue: "Use %@ for This Workspace",
                              table: "BrowserProfileActions", bundle: .localizedModule), name)
    }

    static func browserProfileSignedInAs(_ who: String) -> String {
        String(format: String(localized: "menu.browserProfile.signedInAs", defaultValue: "Signed in as %@",
                              table: "BrowserProfileActions", bundle: .localizedModule), who)
    }

    static var browserProfileCustomize: String {
        String(localized: "menu.browserProfile.customize", defaultValue: "Customize Profile",
               table: "BrowserProfileActions", bundle: .localizedModule)
    }

    static var browserProfileManage: String {
        String(localized: "menu.browserProfile.manage", defaultValue: "Manage Browser Profiles…",
               table: "BrowserProfileActions", bundle: .localizedModule)
    }
}

private extension NSMenu {
    /// Every row, taken out of this menu (a row sits in one menu at a time).
    func itemsRemoved() -> [NSMenuItem] {
        let rows = items
        removeAllItems()
        return rows
    }
}
