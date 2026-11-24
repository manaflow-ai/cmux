import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// The sidebar's top row is the Chief (Lucas 2026-11-23): a look with a title draws "Chief" alone, on the column a
/// text-only workspace title starts on, with no crown; a look with no title (a tile, an icon) keeps the glyph.
@MainActor
@Suite struct SidebarChiefRowTitleOnlyTests {
    static let home = LayoutItemID("itm_home")

    func chiefInfo() throws -> SidebarItemInfo {
        let item = LayoutItem(id: Self.home, ref: SidebarLayoutDocument.homeRef)
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item])])
        return try #require(SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 0)[item.id])
    }

    @Test(arguments: [SidebarItemRowView.Style.builtIn, .list, .chip])
    func aTitledLookDrawsTheTitleAlone(_ style: SidebarItemRowView.Style) throws {
        let info = try chiefInfo()
        #expect(info.hidesGlyphBesideTitle)
        let chief = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        chief.configure(info, style: style)
        chief.layoutSubtreeIfNeeded()
        #expect(chief.icon.image == nil, "\(style): the Chief row draws a glyph")
        // A text-only workspace item's title starts on the same x.
        var textOnly = SidebarItemInfo(title: "Fix tabs", symbol: "terminal")
        textOnly.textOnly = true
        let plain = SidebarItemRowView(frame: chief.frame)
        plain.configure(textOnly, style: style)
        plain.layoutSubtreeIfNeeded()
        #expect(abs(chief.title.frame.minX - plain.title.frame.minX) < 0.01,
                "\(style): Chief's title starts at \(chief.title.frame.minX), a text-only title at \(plain.title.frame.minX)")
    }

    @Test(arguments: [SidebarItemRowView.Style.tile, .icon])
    func aLookWithNoTitleKeepsTheGlyph(_ style: SidebarItemRowView.Style) throws {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 52, height: 52))
        row.configure(try chiefInfo(), style: style)
        row.layoutSubtreeIfNeeded()
        #expect(row.icon.image != nil, "\(style): the Chief tile lost its glyph")
    }
}
