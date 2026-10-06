import AppKit
import CmuxNextActions
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// Leo (2026-10-06): the footer avatar is the signed-in user's, and a click
/// opens the account menu: who is signed in, Accounts, then Sign Out.
@MainActor @Suite struct SidebarAccountMenuTests {
    private let leo = SidebarFooterAccount(name: "Leo Li", email: "leo@example.com")

    @Test func theAccountItemCarriesTheSignedInUsersAvatarAndName() {
        let infos = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, account: leo)
        let info = infos[LayoutItemID("itm_account")]
        #expect(info?.avatar?.initials == "LL")
        #expect(info?.title == "Leo Li", "Show Label on the avatar shows the name")
        let signedOut = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true })[LayoutItemID("itm_account")]
        #expect(signedOut?.avatar == nil && signedOut?.title == SectionStrings.account)
        #expect(SidebarFooterAccount(name: nil, email: "ada@example.com")?.name == "ada@example.com")
        #expect(SidebarFooterAccount(name: " ", email: nil) == nil)
    }

    @Test func theAccountMenuNamesTheUserThenAccountsAndSignOut() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        let menu = SidebarFooterAccount.menu(leo, registry: registry)
        let rows = menu.items.filter { !$0.isSeparatorItem }
        #expect(rows.map(\.title).prefix(2) == ["Leo Li", "leo@example.com"])
        #expect(rows.prefix(2).allSatisfy { !$0.isEnabled }, "the header is not a command")
        #expect(rows.dropFirst(2).map { $0.representedObject as? String } == ["accounts.show", "palette.auth.signOut"])

        let signedOut = SidebarFooterAccount.menu(nil, registry: registry).items.filter { !$0.isSeparatorItem }
        #expect(signedOut.map { $0.representedObject as? String } == ["palette.auth.signIn", "accounts.show"])
    }
}
