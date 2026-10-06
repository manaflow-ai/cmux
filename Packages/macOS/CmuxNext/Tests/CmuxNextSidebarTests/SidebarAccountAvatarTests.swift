import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Leo (2026-10-06): the footer's leading item is the signed-in user's
/// avatar (their picture, else their initials), truly round and at the
/// gear's size; a click opens the account menu instead of a page.
@MainActor @Suite(.serialized) struct SidebarAccountAvatarTests {
    @Test func initialsComeFromTheNameOrEmail() {
        #expect(SidebarAvatar.initials(for: "Leo Li") == "LL")
        #expect(SidebarAvatar.initials(for: "lawrence") == "L")
        #expect(SidebarAvatar.initials(for: "ada lovelace byron") == "AB")
        #expect(SidebarAvatar.initials(for: "ada@example.com") == "A")
        #expect(SidebarAvatar.initials(for: "  ") == "?")
    }

    @Test func anAvatarDrawsRoundAtTheGlyphSizeInsteadOfTheSymbol() throws {
        let view = SidebarItemRowView()
        view.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        view.configure(SidebarItemInfo(title: "Leo Li", symbol: "person.crop.circle", avatar: SidebarAvatar(name: "Leo Li")), style: .icon)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.glyphImage)
        #expect(view.drawsAvatar)
        #expect(!image.isTemplate, "an avatar is not tinted like a glyph")
        #expect(image.size == NSSize(width: SidebarStyle.kindGlyphSize, height: SidebarStyle.kindGlyphSize))
        #expect(view.accessibilityLabel() == "Leo Li")

        view.configure(SidebarItemInfo(title: "Account", symbol: "person.crop.circle"), style: .icon)
        view.layoutSubtreeIfNeeded()
        #expect(!view.drawsAvatar, "signed out keeps the account glyph")
    }

    @Test func anItemWithAMenuOpensItInsteadOfActivating() throws {
        let view = SidebarView(model: SidebarModel())
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        let account = LayoutItemID("itm_account"), settings = LayoutItemID("itm_settings")
        let menu = NSMenu()
        var presented: [(NSMenu, NSView)] = [], activated: [LayoutItemID] = []
        view.itemMenuProvider = { $0 == account ? menu : nil }
        view.presentItemMenu = { presented.append(($0, $1)) }
        view.model.onIntent = { if case .activateItem(let id, _) = $0 { activated.append(id) } }
        let avatar = try #require(view.belowRegion.itemView(account))
        avatar.press(at: .zero)
        #expect(presented.count == 1 && presented.first?.0 === menu && presented.first?.1 === avatar)
        #expect(activated.isEmpty)
        try #require(view.belowRegion.itemView(settings)).press(at: .zero)
        #expect(activated == [settings], "the gear still runs its action")
    }
}
