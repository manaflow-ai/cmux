import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The account menu at the sidebar's bottom left (PRIORITIES 1.14): signed in, who it is, then
/// the selected team, whose row opens the team picker; Sign Out at the end.
@MainActor
struct SidebarAccountMenuTests {
    @Test func signedInTheTeamFollowsWhoItIsAndOpensThePicker() throws {
        let registry = ActionRegistry.standard()
        let menu = NSMenu()
        let account = try #require(SidebarAccount(name: "Ada Lovelace", email: "ada@example.com", team: "Analytical"))
        SidebarAccount.addRows(to: menu, account: account, registry: registry)

        #expect(Array(menu.items.prefix(3).map(\.title)) == ["Ada Lovelace", "ada@example.com", "Analytical"])
        let team = menu.items[2]
        #expect(team.identifier?.rawValue == "cmux.action.openTeamPicker")
        #expect(team.representedObject as? String == "openTeamPicker")
        #expect(team.image != nil)
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items.last?.representedObject as? String == "palette.auth.signOut")
    }

    @Test func noTeamNoTeamRow() throws {
        let menu = NSMenu()
        let account = try #require(SidebarAccount(name: "Ada Lovelace", email: nil, team: ""))
        SidebarAccount.addRows(to: menu, account: account, registry: .standard())
        #expect(!menu.items.contains { $0.representedObject as? String == "openTeamPicker" })
    }
}
