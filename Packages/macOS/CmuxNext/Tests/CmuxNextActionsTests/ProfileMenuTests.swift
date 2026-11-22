import AppKit
import CmuxNextActions
import Testing

/// SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2 (Lawrence 2026-10-07,
/// screenshot): the sidebar's bottom-left avatar opens one native menu,
/// top to bottom: "Profiles" (the current profile, checked, with its "…"
/// options; no "New profile" yet), a separator, Bookmarks › Downloads ›
/// Extensions › History › Developers ›, Settings ⌘,, a separator, New Tab
/// ⌘T and Incognito Window. Every row is a registry item with its effective
/// shortcut and an SF Symbol; rows this build does not register are left out.
@MainActor @Suite struct ProfileMenuTests {
    static let profile = ProfileMenuProfile(name: "Work", initial: "W")

    private func registry(binding ids: [ActionID]? = nil) -> ActionRegistry {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        let spec = ProfileMenuSpec()
        let all = spec.profileActions + spec.submenus.flatMap(\.actions) + [spec.settings.action] + spec.creation.map(\.action)
        for id in ids ?? all { registry.bind(id, handler: {}) }
        return registry
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test func theMenuHasTheScreenshotsRowsInOrder() throws {
        let menu = ProfileMenuBuilder(registry: registry()).make(profile: Self.profile)
        #expect(titles(menu) == ["Profiles", "Work", "—", "Bookmarks", "Downloads", "Extensions", "History", "Developers",
                                 "Settings…", "—", "New Tab", "Incognito Window"])
        #expect(menu.items[0].isSectionHeader)
    }

    @Test func theCurrentProfileIsCheckedWithItsOptionsAndNoNewProfile() throws {
        let menu = ProfileMenuBuilder(registry: registry()).make(profile: Self.profile)
        let row = try #require(menu.items.first { $0.title == "Work" })
        #expect(row.state == .on)
        #expect(row.image != nil, "the avatar")
        let options = try #require(row.submenu)
        #expect(options.items.compactMap { $0.representedObject as? String }
            == ["browserProfile.rename", "browserProfile.setColor", "browserProfile.setIcon", "browserProfile.manageExtensions"])
        let everyAction = Self.actions(in: menu)
        #expect(!everyAction.contains("browserProfile.new"), "New profile waits for the profiles lane")
    }

    @Test func everyRowRunsARegistryActionWithItsShortcutAndSymbol() throws {
        // The registry owns the menu target (weak on the items): keep it alive.
        let owner = registry()
        defer { withExtendedLifetime(owner) {} }
        let menu = ProfileMenuBuilder(registry: owner).make(profile: Self.profile)
        let settings = try #require(menu.items.first { $0.representedObject as? String == "openSettings" })
        #expect(settings.keyEquivalent == "," && settings.keyEquivalentModifierMask == [.command])
        let newTab = try #require(menu.items.first { $0.representedObject as? String == "newTab.sameKind" })
        #expect(newTab.keyEquivalent == "t" && newTab.keyEquivalentModifierMask == [.command])
        let incognito = try #require(menu.items.first { $0.representedObject as? String == "newIncognitoWindow" })
        #expect(incognito.title == "Incognito Window")
        // The top-level rows show SF Symbols.
        for item in menu.items where !item.isSeparatorItem && !item.isSectionHeader {
            #expect(item.image != nil, "\(item.title) has a symbol")
        }
        // Every submenu row is a registry item.
        for item in menu.items {
            for sub in item.submenu?.items ?? [] {
                #expect(sub.representedObject is String, "\(sub.title) runs a registry action")
                #expect(sub.target != nil)
            }
        }
        let history = try #require(menu.items.first { $0.title == "History" }?.submenu)
        #expect(history.items.compactMap { $0.representedObject as? String } == ["history.show", "recentlyClosed", "history.reopen", "history.clear"])
        let downloads = try #require(menu.items.first { $0.title == "Downloads" }?.submenu)
        #expect(downloads.items.compactMap { $0.representedObject as? String } == ["browser.downloads.showFolder"])
    }

    /// A row the build does not register is left out, and a submenu left
    /// with nothing is left out too (omitted, never disabled).
    @Test func unregisteredRowsAndEmptySubmenusAreLeftOut() {
        let menu = ProfileMenuBuilder(registry: registry(binding: ["openSettings", "bookmark.manager"])).make(profile: Self.profile)
        #expect(titles(menu) == ["Profiles", "Work", "—", "Bookmarks", "Settings…"])
        #expect(menu.items[3].submenu?.items.compactMap { $0.representedObject as? String } == ["bookmark.manager"])
    }

    /// The two new actions the menu needs are catalog actions (palette and
    /// `cmux action run`), not menu-only rows.
    @Test func theNewActionsAreInThePalette() throws {
        let catalog = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
        for id: ActionID in ["sidebar.profileMenu", "browser.downloads.showFolder"] {
            let descriptor = try #require(catalog[id], "\(id)")
            #expect(descriptor.surfaces.contains(.palette), "\(id)")
        }
    }

    static func actions(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item in [item.representedObject as? String].compactMap { $0 } + (item.submenu.map { actions(in: $0) } ?? []) }
    }
}
