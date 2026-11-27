import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The account menu at the sidebar's bottom left (PRIORITIES 1.14): signed in, who it is (a row
/// that opens Accounts…), then every team the account may work in, the active one checked; Sign
/// Out at the end. Leo, 2026-11-09: "i guess is team? it's kinda hard to realize tho" and, of the
/// greyed email, "but does this not mean it's already connected?"
@MainActor
struct SidebarAccountMenuTests {
    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.bind("openTeamPicker") {}
        registry.bind("accounts.show") {}
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.cloudTeams
                ? [ActionEnumCase(value: "t1", title: "cmux", subtitle: "Team · Team plan", symbol: "person.2"),
                   ActionEnumCase(value: "t2", title: "leo@example.com's Team", subtitle: "Team", symbol: "person.2"),
                   ActionEnumCase(value: "t3", title: "Personal", subtitle: "ada@example.com", symbol: "person")]
                : []
        }
        registry.choiceState = { id, _ in id == "openTeamPicker" ? "t1" : nil }
        return registry
    }

    @Test func signedInTheTeamsFollowWhoItIsWithTheActiveOneChecked() throws {
        let menu = NSMenu()
        let account = try #require(SidebarAccount(name: "Ada Lovelace", email: "ada@example.com", team: "cmux"))
        SidebarAccount.addRows(to: menu, account: account, registry: Self.registry())

        let person = try #require(menu.items.first)
        #expect(person.identifier?.rawValue == "profileMenu.person")
        #expect(person.title == "Ada Lovelace")
        // Who it is is a normal row that opens Accounts…, never a greyed header.
        #expect(person.isEnabled && person.action != nil)
        #expect(person.representedObject as? String == "accounts.show")

        let teams = menu.items.filter { $0.identifier?.rawValue == "profileMenu.team" }
        #expect(teams.map(\.title) == ["cmux", "leo@example.com's Team", "Personal"])
        // Exactly one row carries the checkmark: the active team.
        #expect(teams.filter { $0.state == .on }.map(\.title) == ["cmux"])
        #expect(menu.items.filter { $0.state == .on }.count == 1)
        // The person's own team is a normal, selectable row like the others.
        let personal = try #require(teams.last)
        #expect(personal.isEnabled && personal.action != nil && personal.image != nil)
        if #available(macOS 14.4, *) {
            #expect(teams.map(\.subtitle) == ["Team · Team plan", "Team", "ada@example.com"])
        }
        #expect(menu.items.last?.representedObject as? String == "palette.auth.signOut")
    }

    @Test func noTeamNoTeamRow() throws {
        let menu = NSMenu()
        let account = try #require(SidebarAccount(name: "Ada Lovelace", email: nil, team: ""))
        SidebarAccount.addRows(to: menu, account: account, registry: .standard())
        #expect(!menu.items.contains { $0.identifier?.rawValue == "profileMenu.team" })
    }

    /// The footer shows the avatar alone (Leo 2026-10-21: "remove the email name area, just make
    /// it a good icon"): the email moves to its tooltip, and the initials sit on the theme accent.
    @Test func theAccountAvatarSaysTheEmailOnHoverAndWearsTheAccent() throws {
        let named = try #require(SidebarAccount(name: "Ada Lovelace", email: "ada@example.com"))
        #expect(named.avatar.toolTip == "ada@example.com")
        #expect(named.avatar.initial == "AL")
        #expect(named.avatar.color == nil, "no profile color: the theme accent")
        let emailOnly = try #require(SidebarAccount(name: nil, email: "leo@cmux.com"))
        #expect(emailOnly.avatar.toolTip == "leo@cmux.com")
        #expect(emailOnly.avatar.initial == "L")
    }
}
