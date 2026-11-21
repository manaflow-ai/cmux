public import AppKit

extension ActionRegistry {
    /// The browser toolbar's profile button menu for the tab `tabKey` (https://github.com/manaflow-ai/cmux/issues/42437):
    /// one row per profile in `profiles` (`id`, shown `title`), the tab's own (`current`) checked and running nothing,
    /// each other moving the tab with `browserProfile.moveTab`; then the tab's profile's own menu as its badge shows it
    /// (New Tab, Window and Workspace with it, New Browser Profile, Rename, Appearance, Manage Extensions, Clear Browsing
    /// Data, Delete), unless `profileActions` is false (an incognito tab's data is no profile's); then Import from
    /// Browser and the Web Store. Every row is a palette action (`MenuPaletteParityTests`).
    public func makeBrowserProfileMenu(tabKey: String, current: String, profiles: [(id: String, title: String)],
                                       profileActions: Bool = true) -> NSMenu {
        let target = ActionTargetRef(kind: .tab, id: tabKey)
        let menu = NSMenu()
        for profile in profiles {
            guard profile.id != current else {
                let item = NSMenuItem(title: profile.title, action: nil, keyEquivalent: "")
                item.state = .on
                menu.addItem(item)
                continue
            }
            if let item = makeContextMenuItem(for: "browserProfile.moveTab", in: .browserPage, target: target,
                                              arguments: ["browserProfile": .string(profile.id)], title: profile.title) {
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        var parts: [NSMenu] = []
        if profileActions {
            parts.append(makeContextMenu(for: .browserProfile, target: ActionTargetRef(kind: .browserProfile, id: current),
                                         arguments: ["tab": .target(target)], customize: false))
        }
        // Without the profile's rows (an incognito tab) New Browser Profile and the tab's extensions stay, as page rows:
        // neither touches a profile's data. A built menu drops a leading separator, so the one above them is added here.
        let page: [ContextMenuEntry] = (profileActions ? [] : [.action("browserProfile.new")]) + [.action("importFromBrowser")]
            + (profileActions ? [] : [.action("browser.extensions.manage")]) + [.action("browser.extensions.webStore")]
        parts.append(makeContextMenu(for: .browserPage, target: target, entries: page))
        for part in parts where !part.items.isEmpty {
            if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            for item in part.items {
                part.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }
}
