import AppKit
@testable import CmuxNextActions
import Testing

/// The profile menu starts with the current avatar row. A separate "Profiles"
/// header and checkmark add chrome without helping when there is one profile.
@MainActor
struct ProfileMenuBuilderTests {
    @Test func currentProfileIsTheFirstRowWithItsAvatar() {
        let avatar = NSImage(size: NSSize(width: 16, height: 16))
        let menu = ProfileMenuBuilder(registry: .standard()).make(
            profile: ProfileMenuProfile(name: "Default"), avatar: avatar)

        let first = menu.items.first
        #expect(first?.title == "Default")
        #expect(first?.identifier?.rawValue == "profileMenu.currentProfile")
        #expect(first?.state == .off)
        #expect(first?.image?.size == avatar.size)
        #expect(!menu.items.contains { $0.title == "Profiles" })
    }

    /// Check for Updates… sits under Settings, as in the app menu (Austin 2026-10-20).
    @Test func checkForUpdatesFollowsSettings() throws {
        let registry = ActionRegistry.standard()
        registry.bind("openSettings") {}
        registry.bind("palette.checkForUpdates") {}
        let menu = ProfileMenuBuilder(registry: registry).make(profile: ProfileMenuProfile(name: "Default"))
        let settings = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "cmux.action.openSettings" })
        let updates = menu.items[settings + 1]
        #expect(updates.identifier?.rawValue == "cmux.action.palette.checkForUpdates")
        #expect(updates.title == "Check for Updates…")
        #expect(updates.representedObject as? String == "palette.checkForUpdates")
    }

    /// One settings area (David Beyer, 2026-11-20: "Personalization and Settings are redundant"): the menu has no
    /// second Personalization… row beside Settings…, even in a build that binds `appearance.personalize` (it opens
    /// Settings > Appearance).
    @Test func oneSettingsRow() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["appearance.personalize", "openSettings"] { registry.bind(id) {} }
        let menu = ProfileMenuBuilder(registry: registry).make(profile: ProfileMenuProfile(name: "Default"))
        let ids = menu.items.map { $0.identifier?.rawValue }
        #expect(ids.contains("cmux.action.openSettings"))
        #expect(!ids.contains("cmux.action.appearance.personalize"))
        #expect(!menu.items.contains { $0.title == "Personalization…" })
    }

    /// The signed-in person leads the menu: their picture on their name's row.
    @Test func thePersonLeadsWithTheirAvatar() throws {
        let registry = ActionRegistry.standard()
        registry.bind("openSettings") {}
        let builder = ProfileMenuBuilder(registry: registry)
        let menu = builder.make(profile: ProfileMenuProfile(name: "Default"))
        let picture = NSImage(size: NSSize(width: 14, height: 14))
        builder.addAccountRows(to: menu, who: ["Sample User", "user@example.com"], avatar: picture)
        let first = try #require(menu.items.first)
        #expect(first.identifier?.rawValue == "profileMenu.person")
        #expect(first.title == "Sample User")
        #expect(first.image === picture)
        // The email is the person row's second line where the system draws one (macOS 14.4).
        if #available(macOS 14.4, *) { #expect(first.subtitle == "user@example.com") }
        // Who it is takes the profile's place: one account row.
        #expect(!menu.items.contains { $0.identifier?.rawValue == "profileMenu.currentProfile" })
    }

    /// Cloud sits above Settings (PRIORITIES 1.14), a registry row; Accounts… is the last row of the account row's
    /// submenu. A build that does not bind one leaves it out.
    @Test func cloudPrecedesSettingsAndAccountsIsInTheAccountRow() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["openSettings", "accounts.show", "palette.openCloudPane"] { registry.bind(id) {} }
        let menu = ProfileMenuBuilder(registry: registry).make(profile: ProfileMenuProfile(name: "Default"))
        let ids = menu.items.map { $0.identifier?.rawValue }
        let settings = try #require(ids.firstIndex(of: "cmux.action.openSettings"))
        #expect(ids[settings - 1] == "cmux.action.palette.openCloudPane")
        #expect(menu.items[settings - 1].title == "Cloud")
        #expect(menu.items[settings - 1].image != nil)
        #expect(!ids.contains("cmux.action.accounts.show"), "Accounts… is a top-level row")
        let profile = try #require(menu.items.first?.submenu)
        #expect(profile.items.last?.identifier?.rawValue == "cmux.action.accounts.show")

        let bare = ActionRegistry.standard()
        bare.bind("openSettings") {}
        let without = ProfileMenuBuilder(registry: bare).make(profile: ProfileMenuProfile(name: "Default")).items
        #expect(!without.contains { $0.identifier?.rawValue == "cmux.action.palette.openCloudPane" })
    }

    /// The menu is as short as the Codex app's account menu (Lawrence, 2026-11-23: "like this menu is ugly as well;
    /// we need better menu design. potentially let's just match these screenshots"): one account row, a short list,
    /// Help and Sign Out. Lawrence, 2026-11-24, of that menu: "show chief/show chief pet is not useful. fix. we should
    /// have new workspace and new window shortcuts still. should show extensions and history still. new window good
    /// too." So New Workspace and New Window lead the list, Extensions and History come back as submenus, and no row
    /// shows the Chief or its pet.
    @Test func theSignedInMenuIsShortLikeCodex() throws {
        let menu = Self.signedInMenu()
        let outline = menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
        #expect(outline == [
            "Sample User", "|",
            "New Workspace", "New Window", "|",
            "Extensions", "History", "Cloud", "Settings…", "Check for Updates…", "|",
            "Help", "Sign Out",
        ])
        #expect(menu.items.first?.identifier?.rawValue == "profileMenu.person")
        for gone in ["Show Chief", "Show Chief Pet", "Hide Chief Pet", "Bookmarks", "Downloads", "Developers", "New Tab",
                     "Incognito Window", "Default"] {
            #expect(!outline.contains(gone), "\(gone) is still in the account menu")
        }
        let help = try #require(menu.items.first { $0.identifier?.rawValue == "profileMenu.help" }?.submenu)
        #expect(help.items.contains { $0.identifier?.rawValue == "cmux.action.help.documentation" })
    }

    /// New Workspace and New Window show their shortcuts (⌘N, ⇧⌘N), as the File menu does, and run the File menu's
    /// own actions.
    @Test func newWorkspaceAndNewWindowShowTheirShortcuts() throws {
        let menu = Self.signedInMenu()
        let workspace = try #require(menu.items.first { $0.title == "New Workspace" })
        #expect(workspace.representedObject as? String == "newTab")
        #expect(workspace.keyEquivalent == "n" && workspace.keyEquivalentModifierMask == [.command])
        #expect(workspace.image != nil)
        let window = try #require(menu.items.first { $0.title == "New Window" })
        #expect(window.representedObject as? String == "newWindow")
        #expect(window.keyEquivalent == "n" && window.keyEquivalentModifierMask == [.command, .shift])
        #expect(window.image != nil)
    }

    /// Extensions › and History › are back (Lawrence, 2026-11-24): each opens the browser's own rows for it.
    @Test func extensionsAndHistoryOpenTheirRows() throws {
        let menu = Self.signedInMenu()
        let extensions = try #require(menu.items.first { $0.title == "Extensions" }?.submenu)
        #expect(extensions.items.contains { $0.identifier?.rawValue == "cmux.action.browser.extensions.manage" })
        let history = try #require(menu.items.first { $0.title == "History" }?.submenu)
        #expect(history.items.contains { $0.identifier?.rawValue == "cmux.action.history.show" })
        #expect(history.items.contains { $0.identifier?.rawValue == "cmux.action.history.clear" })
    }

    /// The account row's chevron opens the teams, the active one checked, then Accounts… (as the Codex app's
    /// account row opens its workspaces); no team is a top-level row and none carries a "Team" second line.
    @Test func theTeamsAreTheAccountRowsSubmenu() throws {
        let menu = Self.signedInMenu()
        #expect(!menu.items.contains { $0.identifier?.rawValue == "profileMenu.team" })
        let submenu = try #require(menu.items.first?.submenu)
        let teams = submenu.items.filter { $0.identifier?.rawValue == "profileMenu.team" }
        #expect(teams.map(\.title) == ["cmux", "cmux-lab"])
        #expect(teams.map(\.state) == [.off, .on])
        if #available(macOS 14.4, *) { #expect(teams.allSatisfy { $0.subtitle == nil }) }
        #expect(submenu.items.last?.identifier?.rawValue == "cmux.action.accounts.show")
        // The browser profile's options stay reachable, under the teams.
        #expect(submenu.items.contains { $0.identifier?.rawValue == "cmux.action.browserProfile.rename" })
        let run = try #require(ActionRegistry.menuRun(of: teams[1]))
        #expect(run.id == "openTeamPicker")
        #expect(run.arguments["team"] == .string("lab"))
    }

    /// Signed in with two teams, every row of the spec bound.
    private static func signedInMenu() -> NSMenu {
        let registry = ActionRegistry.standard()
        let ids: [ActionID] = ["home.openChief", "palette.toggleSetting", "palette.openCloudPane", "openSettings",
                               "palette.checkForUpdates", "accounts.show", "openTeamPicker", "palette.auth.signOut",
                               "help.documentation", "palette.searchShortcuts", "updates.whatsNew", "sendFeedback",
                               "browserProfile.rename", "newTab", "newWindow", "browser.extensions.manage",
                               "browser.extensions.webStore", "browser.extensions.loadUnpacked", "history.show",
                               "recentlyClosed", "history.reopen", "history.clear"]
        for id in ids { registry.bind(id) {} }
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.cloudTeams else { return [] }
            return [ActionEnumCase(value: "cmux", title: "cmux", subtitle: "Team", symbol: "person.2"),
                    ActionEnumCase(value: "lab", title: "cmux-lab", subtitle: "Team", symbol: "person.2")]
        }
        registry.choiceState = { id, _ in id == "openTeamPicker" ? "lab" : nil }
        let builder = ProfileMenuBuilder(registry: registry)
        let menu = builder.make(profile: ProfileMenuProfile(name: "Default"))
        builder.addAccountRows(to: menu, who: ["Sample User", "user@example.com"])
        return menu
    }
}
