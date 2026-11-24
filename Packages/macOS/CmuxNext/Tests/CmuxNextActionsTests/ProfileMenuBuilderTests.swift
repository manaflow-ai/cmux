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

    /// Show Chief Pet / Hide Chief Pet (Leo 2026-10-20; Codex's profile menu toggles its floating window):
    /// the row flips `home.chiefPetEnabled` through the one setting path, `palette.toggleSetting`. It says
    /// Pet (David Beyer, Nov 20): "Show Chief" is the row that shows the Chief.
    @Test func chiefRowShowsOrHidesThePetThroughTheSettingPath() throws {
        // The App binds both; a row whose action is not bound is left out.
        let registry = ActionRegistry.standard()
        registry.bind("palette.toggleSetting") {}
        registry.bind("openSettings") {}
        let builder = ProfileMenuBuilder(registry: registry)
        let profile = ProfileMenuProfile(name: "Default")

        let hidden = builder.make(profile: profile, chiefPetShown: false)
        let show = try #require(hidden.items.first { $0.identifier?.rawValue == "profileMenu.chiefPet" })
        #expect(show.title == "Show Chief Pet")
        let showRun = try #require(ActionRegistry.menuRun(of: show))
        #expect(showRun.id == "palette.toggleSetting")
        #expect(showRun.arguments["setting"] == .string("home.chiefPetEnabled"))
        #expect(showRun.arguments["on"] == .bool(true))

        let shown = builder.make(profile: profile, chiefPetShown: true)
        let hide = try #require(shown.items.first { $0.identifier?.rawValue == "profileMenu.chiefPet" })
        #expect(hide.title == "Hide Chief Pet")
        #expect(ActionRegistry.menuRun(of: hide)?.arguments["on"] == .bool(false))

        // It sits just above Settings.
        let index = try #require(shown.items.firstIndex(of: hide))
        #expect(shown.items[index + 1].identifier?.rawValue == "cmux.action.openSettings")

        // A caller with no pet to show gets no row.
        #expect(!builder.make(profile: profile).items.contains { $0.identifier?.rawValue == "profileMenu.chiefPet" })
    }

    /// Show Chief (David Beyer, Nov 20: "Show Chief" did not show the Chief unless he went to Home): the row
    /// always opens the Chief (`home.openChief`: its conversation, or the side panel), above the pet's row.
    @Test func showChiefOpensTheChief() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["home.openChief", "palette.toggleSetting", "openSettings"] { registry.bind(id) {} }
        let builder = ProfileMenuBuilder(registry: registry)
        for petShown in [false, true] {
            let menu = builder.make(profile: ProfileMenuProfile(name: "Default"), chiefPetShown: petShown)
            let row = try #require(menu.items.first { $0.identifier?.rawValue == "profileMenu.showChief" }, "no Show Chief row")
            #expect(row.title == "Show Chief")
            #expect(row.image != nil)
            #expect(ActionRegistry.menuRun(of: row)?.id == "home.openChief" || row.representedObject as? String == "home.openChief",
                    "Show Chief does not open the Chief")
            let ids = menu.items.map { $0.identifier?.rawValue }
            let chief = try #require(ids.firstIndex(of: "profileMenu.showChief"))
            #expect(ids[chief + 1] == "profileMenu.chiefPet", "the pet's row is not right under Show Chief")
        }
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

    /// One settings area (David Beyer, 2026-11-20: "Personalization and Settings are redundant"):
    /// Settings… follows Show Chief, and the menu has no second Personalization… row beside it,
    /// even in a build that binds `appearance.personalize` (it opens Settings > Appearance).
    @Test func oneSettingsRowFollowsShowChief() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["palette.toggleSetting", "appearance.personalize", "openSettings"] { registry.bind(id) {} }
        let menu = ProfileMenuBuilder(registry: registry).make(profile: ProfileMenuProfile(name: "Default"), chiefPetShown: false)
        let ids = menu.items.map { $0.identifier?.rawValue }
        let chief = try #require(ids.firstIndex(of: "profileMenu.chiefPet"))
        #expect(ids[chief + 1] == "cmux.action.openSettings")
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
    /// Help and Sign Out. The browser's rows are the More (⋮) menu's, so none of them is here.
    @Test func theSignedInMenuIsShortLikeCodex() throws {
        let menu = Self.signedInMenu()
        let outline = menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
        #expect(outline == [
            "Sample User", "|",
            "Show Chief", "Show Chief Pet", "Cloud", "Settings…", "Check for Updates…", "|",
            "Help", "Sign Out",
        ])
        #expect(menu.items.first?.identifier?.rawValue == "profileMenu.person")
        for gone in ["Bookmarks", "Downloads", "Extensions", "History", "Developers", "New Tab", "Incognito Window", "Default"] {
            #expect(!outline.contains(gone), "\(gone) is still in the account menu")
        }
        let help = try #require(menu.items.first { $0.identifier?.rawValue == "profileMenu.help" }?.submenu)
        #expect(help.items.contains { $0.identifier?.rawValue == "cmux.action.help.documentation" })
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
                               "browserProfile.rename"]
        for id in ids { registry.bind(id) {} }
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.cloudTeams else { return [] }
            return [ActionEnumCase(value: "cmux", title: "cmux", subtitle: "Team", symbol: "person.2"),
                    ActionEnumCase(value: "lab", title: "cmux-lab", subtitle: "Team", symbol: "person.2")]
        }
        registry.choiceState = { id, _ in id == "openTeamPicker" ? "lab" : nil }
        let builder = ProfileMenuBuilder(registry: registry)
        let menu = builder.make(profile: ProfileMenuProfile(name: "Default"), chiefPetShown: false)
        builder.addAccountRows(to: menu, who: ["Sample User", "user@example.com"])
        return menu
    }
}
