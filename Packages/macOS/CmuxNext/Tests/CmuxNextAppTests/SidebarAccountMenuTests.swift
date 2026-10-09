import AppKit
import CmuxNextActions
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// #17601 on base's profile control (leoli-24, 2026-10-07): signed in, the
/// control is the cmux user's avatar and its menu says who is signed in and
/// ends with Sign Out; signed out, it keeps the profile's avatar and the menu
/// ends with Sign In.
@MainActor @Suite struct SidebarAccountMenuTests {
    private let leo = SidebarAccount(name: "Leo Li", email: "leo@example.com")
    private let profile = SidebarAvatar(name: "Work", color: .blue)

    private func menu(_ account: SidebarAccount?) -> NSMenu {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        let menu = ProfileMenuBuilder(registry: registry).make(profile: ProfileMenuProfile(name: "Work", initial: "W"))
        SidebarAccount.addRows(to: menu, account: account, registry: registry)
        return menu
    }

    @Test func signedInTheControlIsTheUsersAvatar() {
        let avatar = SidebarProfileControl.avatar(profile: profile, account: leo)
        #expect(avatar.name == "Leo Li" && avatar.initial == "LL" && avatar.color == nil)
        #expect(SidebarProfileControl.avatar(profile: profile, account: nil) == profile)
        #expect(SidebarAccount(name: nil, email: "ada@example.com")?.name == "ada@example.com")
        #expect(SidebarAccount(name: nil, email: "ada@example.com")?.email == nil, "the email is not shown twice")
        #expect(SidebarAccount(name: " ", email: nil) == nil)
    }

    @Test func signedInTheMenuNamesTheUserAndEndsWithSignOut() throws {
        let items = menu(leo).items
        #expect(items.prefix(3).map { $0.isSeparatorItem ? "—" : $0.title } == ["Leo Li", "leo@example.com", "—"])
        #expect(items.prefix(2).allSatisfy { !$0.isEnabled && $0.action == nil }, "who is signed in is not a command")
        #expect(items[3].isSectionHeader, "then base's Profiles section")
        let last = try #require(items.last)
        #expect(last.representedObject as? String == "palette.auth.signOut")
        #expect(items[items.count - 2].isSeparatorItem)
        #expect(!items.contains { $0.representedObject as? String == "palette.auth.signIn" })
    }

    @Test func signedOutTheMenuEndsWithSignIn() throws {
        let items = menu(nil).items
        #expect(items.first?.isSectionHeader == true, "no account rows on top")
        #expect(items.last?.representedObject as? String == "palette.auth.signIn")
        #expect(!items.contains { $0.representedObject as? String == "palette.auth.signOut" })
    }
}
