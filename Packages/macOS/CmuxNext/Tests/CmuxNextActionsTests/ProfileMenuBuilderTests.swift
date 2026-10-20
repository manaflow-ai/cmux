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

    /// Show Chief / Hide Chief (Leo 2026-10-20; Codex's profile menu toggles its floating window):
    /// the row flips `home.chiefPetEnabled` through the one setting path, `palette.toggleSetting`.
    @Test func chiefRowShowsOrHidesThePetThroughTheSettingPath() throws {
        // The App binds both; a row whose action is not bound is left out.
        let registry = ActionRegistry.standard()
        registry.bind("palette.toggleSetting") {}
        registry.bind("openSettings") {}
        let builder = ProfileMenuBuilder(registry: registry)
        let profile = ProfileMenuProfile(name: "Default")

        let hidden = builder.make(profile: profile, chiefPetShown: false)
        let show = try #require(hidden.items.first { $0.identifier?.rawValue == "profileMenu.chiefPet" })
        #expect(show.title == "Show Chief")
        let showRun = try #require(ActionRegistry.menuRun(of: show))
        #expect(showRun.id == "palette.toggleSetting")
        #expect(showRun.arguments["setting"] == .string("home.chiefPetEnabled"))
        #expect(showRun.arguments["on"] == .bool(true))

        let shown = builder.make(profile: profile, chiefPetShown: true)
        let hide = try #require(shown.items.first { $0.identifier?.rawValue == "profileMenu.chiefPet" })
        #expect(hide.title == "Hide Chief")
        #expect(ActionRegistry.menuRun(of: hide)?.arguments["on"] == .bool(false))

        // It sits just above Settings.
        let index = try #require(shown.items.firstIndex(of: hide))
        #expect(shown.items[index + 1].identifier?.rawValue == "cmux.action.openSettings")

        // A caller with no pet to show gets no row.
        #expect(!builder.make(profile: profile).items.contains { $0.identifier?.rawValue == "profileMenu.chiefPet" })
    }
}
