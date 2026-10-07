import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The footer section (`SidebarLayoutDocument.bottomSectionID`: the profile
/// control and the space dots in its row) is pinned at the sidebar's bottom.
/// A tall bottom-region section above it (the Chats section of
/// `sidebar.showChats`) scrolls in the capped band; the footer never scrolls
/// out of view, even in a small window.
@MainActor @Suite(.serialized) struct SidebarFooterPinTests {
    static let account = LayoutItemID("itm_account")
    static let tallSection = LayoutSectionID("sec_pin_tall")

    private func shortSidebarWithTallBottomSection() throws -> SidebarView {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("default"), name: "Default"), SidebarProfile(id: ProfileKey("p2"), name: "Two")]
        model.activeProfileID = ProfileKey("default")
        var info = SidebarBuiltIn.account.defaultInfo
        info.avatar = SidebarAvatar(name: "Work", color: nil)
        info.title = "Work"
        model.itemInfo = [Self.account: info]
        var doc = SidebarLayoutDocument.defaults
        let tall = LayoutSection(id: Self.tallSection, title: "Chats", region: .bottom, look: .list,
                                 items: (0..<24).map { LayoutItem(id: LayoutItemID("itm_pin_\($0)"), ref: .url("https://example.com/\($0)")) })
        let footer = try #require(doc.sections.firstIndex { $0.id == SidebarLayoutDocument.bottomSectionID })
        doc.sections.insert(tall, at: footer)
        model.layout = doc
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    /// The account control is inside the sidebar and not clipped by any band
    /// scroll view; the tall section still scrolls above it.
    @Test func theFooterStaysVisibleUnderATallScrollingBottomSection() throws {
        let view = try shortSidebarWithTallBottomSection()
        let account = try #require(view.footerRegion.itemView(Self.account))
        #expect(!account.isHiddenOrHasHiddenAncestor)
        let frame = account.convert(account.bounds, to: view)
        #expect(frame.height > 0 && view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) in \(view.bounds)")
        if let scroll = account.enclosingScrollView {
            let visible = scroll.contentView.convert(scroll.contentView.bounds, to: view)
            #expect(visible.insetBy(dx: -0.5, dy: -0.5).contains(frame), "clipped by the band: \(frame) in \(visible)")
        }
        // The tall section is in the scrolling band, above the footer, and scrolls.
        #expect(view.belowRegion.itemView(LayoutItemID("itm_pin_0")) != nil)
        #expect(view.belowRegion.frame.height > view.belowScroll.contentView.bounds.height + 0.5, "the band scrolls")
        #expect(view.belowFade.frame.maxY <= frame.minY + 0.5, "the band ends above the footer: \(view.belowFade.frame) \(frame)")
    }

    /// The dots stay in the account's row, right after it.
    @Test func theDotsStayInThePinnedAccountRow() throws {
        let view = try shortSidebarWithTallBottomSection()
        let account = try #require(view.footerRegion.itemView(Self.account))
        let frame = account.convert(account.bounds, to: view)
        let bar = view.convert(view.profileBar.frame, from: view.profileBar.superview)
        #expect(bar.height > 0 && abs(bar.midY - frame.midY) <= 0.5, "one row: \(bar) \(frame)")
        #expect(bar.minX >= frame.maxX - 0.5, "after the control: \(bar) \(frame)")
        #expect(view.footer.frame.height == 0, "no separate dots row")
    }
}
