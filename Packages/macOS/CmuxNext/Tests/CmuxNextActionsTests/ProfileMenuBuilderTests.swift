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
        // The email is the person row's second line where the system draws one, else its own row.
        if #available(macOS 14.4, *) {
            #expect(first.subtitle == "user@example.com")
        } else {
            #expect(menu.items[1].title == "user@example.com")
        }
    }

    /// The account menu (PRIORITIES 1.14): Accounts… and Cloud sit under Settings, each a
    /// registry row, and a build that does not bind one leaves it out.
    @Test func accountsAndCloudFollowSettings() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["openSettings", "accounts.show", "palette.openCloudPane"] { registry.bind(id) {} }
        let menu = ProfileMenuBuilder(registry: registry).make(profile: ProfileMenuProfile(name: "Default"))
        let ids = menu.items.map { $0.identifier?.rawValue }
        let settings = try #require(ids.firstIndex(of: "cmux.action.openSettings"))
        #expect(ids[settings + 1] == "cmux.action.accounts.show")
        #expect(ids[settings + 2] == "cmux.action.palette.openCloudPane")
        #expect(menu.items[settings + 2].title == "Cloud")
        #expect(menu.items[settings + 2].image != nil)

        let bare = ActionRegistry.standard()
        bare.bind("openSettings") {}
        let without = ProfileMenuBuilder(registry: bare).make(profile: ProfileMenuProfile(name: "Default")).items
        #expect(!without.contains { $0.identifier?.rawValue == "cmux.action.palette.openCloudPane" })
    }
}
