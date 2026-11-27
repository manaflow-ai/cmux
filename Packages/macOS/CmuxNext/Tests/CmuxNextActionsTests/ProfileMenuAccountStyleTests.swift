import AppKit
@testable import CmuxNextActions
import Testing

/// `sidebar.profileMenu.style: "account"` (ask-aad661801e: the Claude Code and Codex apps' account menus): the person
/// and their teams first, then Settings, Usage, Help and Sign Out; none of the app menu's rows.
@MainActor
struct ProfileMenuAccountStyleTests {
    @Test func signedInLeadsWithThePersonThenTheTeamsThenSettingsUsageHelpSignOut() throws {
        let picture = NSImage(size: NSSize(width: 14, height: 14))
        let menu = Self.builder().makeAccount(who: ["Sample User", "user@example.com"], avatar: picture)
        let person = try #require(menu.items.first)
        #expect(person.identifier?.rawValue == "profileMenu.person")
        #expect(person.title == "Sample User")
        #expect(person.image === picture)
        if #available(macOS 14.4, *) { #expect(person.subtitle == "user@example.com") }
        // Who it is is a row that opens something (Accounts…), never a greyed header (Leo, 2026-11-09).
        #expect(try #require(ActionRegistry.menuRun(of: person)).id == "accounts.show")

        let rows = menu.items.map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? $0.title) }
        #expect(rows == ["profileMenu.person", "-", "profileMenu.team", "profileMenu.team", "-",
                         "cmux.action.openSettings", "cmux.action.chief.openUsage", "-", "profileMenu.help", "-",
                         "cmux.action.palette.auth.signOut"])
        let usage = try #require(menu.items.first { $0.identifier?.rawValue == "cmux.action.chief.openUsage" })
        #expect(usage.title == "Usage")
    }

    /// Switching: the teams are Switch Active Team's own values, the active one checked, a click running it with the
    /// team picked.
    @Test func theTeamsSwitchTheActiveTeam() throws {
        let menu = Self.builder().makeAccount(who: ["Sample User"])
        let teams = menu.items.filter { $0.identifier?.rawValue == "profileMenu.team" }
        #expect(teams.map(\.title) == ["cmux", "cmux-lab"])
        #expect(teams.map(\.state) == [.off, .on])
        let run = try #require(ActionRegistry.menuRun(of: teams[0]))
        #expect(run.id == "openTeamPicker")
        #expect(run.arguments["team"] == .string("cmux"))
    }

    /// Signed out: Accounts… leads, no teams, Sign In ends the menu.
    @Test func signedOutLeadsWithAccountsAndEndsWithSignIn() {
        let menu = Self.builder().makeAccount(who: nil)
        #expect(menu.items.first?.identifier?.rawValue == "cmux.action.accounts.show")
        #expect(!menu.items.contains { $0.identifier?.rawValue == "profileMenu.team" })
        #expect(menu.items.last?.identifier?.rawValue == "cmux.action.palette.auth.signIn")
    }

    /// The app menu's rows stay in the app menu.
    @Test func noAppRows() {
        let ids = Self.builder().makeAccount(who: ["Sample User"]).items.compactMap { $0.identifier?.rawValue }
        for id in ["newTab", "newWindow", "palette.openCloudPane", "palette.checkForUpdates"] {
            #expect(!ids.contains("cmux.action.\(id)"))
        }
        #expect(!ids.contains("profileMenu.currentProfile"))
    }

    /// The sidebar's path: the app menu built, then `addAccountRows(accountFirst:)` turns it into the account menu.
    @Test func accountFirstTurnsTheAppMenuIntoTheAccountMenu() {
        let builder = Self.builder()
        let menu = builder.make(profile: ProfileMenuProfile(name: "Default"))
        builder.addAccountRows(to: menu, who: ["Sample User", "user@example.com"], accountFirst: true)
        let expected = builder.makeAccount(who: ["Sample User", "user@example.com"])
        #expect(menu.items.map(\.title) == expected.items.map(\.title))
        #expect(menu.items.first?.identifier?.rawValue == "profileMenu.person")
    }

    /// A build with no usage to show (no local Chief) leaves Usage out instead of drawing it disabled.
    @Test func usageIsLeftOutWhereTheBuildHasNone() {
        let registry = Self.registry()
        registry.bindUnavailable("chief.openUsage", reason: "No local Chief")
        let ids = ProfileMenuBuilder(registry: registry).makeAccount(who: ["Sample User"]).items.compactMap { $0.identifier?.rawValue }
        #expect(!ids.contains("cmux.action.chief.openUsage"))
        #expect(ids.contains("cmux.action.openSettings"))
    }

    private static func builder() -> ProfileMenuBuilder { ProfileMenuBuilder(registry: registry()) }

    private static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        let ids: [ActionID] = ["openSettings", "chief.openUsage", "accounts.show", "openTeamPicker", "palette.auth.signOut",
                               "palette.auth.signIn", "help.documentation", "palette.searchShortcuts", "updates.whatsNew",
                               "sendFeedback", "newTab", "newWindow", "palette.openCloudPane", "palette.checkForUpdates"]
        for id in ids { registry.bind(id) {} }
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.cloudTeams else { return [] }
            return [ActionEnumCase(value: "cmux", title: "cmux", subtitle: "Team", symbol: "person.2"),
                    ActionEnumCase(value: "lab", title: "cmux-lab", subtitle: "Team", symbol: "person.2")]
        }
        registry.choiceState = { id, _ in id == "openTeamPicker" ? "lab" : nil }
        return registry
    }
}
