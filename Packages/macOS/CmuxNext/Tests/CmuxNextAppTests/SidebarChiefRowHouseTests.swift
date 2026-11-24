import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// The sidebar's top row is the Chief, drawn with Home's house (Lucas 2026-11-23: "add the home icon to the sidebar
/// chief"): every look draws the house glyph, a titled look beside "Chief", even when the Chief wears a picture.
@MainActor
@Suite struct SidebarChiefRowHouseTests {
    static let home = LayoutItemID("itm_home")

    func chiefInfo(picture: SidebarFavicon? = nil) throws -> SidebarItemInfo {
        let item = LayoutItem(id: Self.home, ref: SidebarLayoutDocument.homeRef)
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item])])
        return try #require(SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 0,
                                                   chiefFavicon: picture)[item.id])
    }

    @Test func theTopRowWearsTheHouseNotTheChiefsPicture() throws {
        let image = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let info = try chiefInfo(picture: SidebarFavicon(image))
        #expect(info.title == SidebarBuiltIn.home.title)
        #expect(info.symbol == "house")
        #expect(info.icon == .home)
        #expect(info.favicon == nil, "the Chief's picture replaced the house on the top row")
    }

    @Test(arguments: [SidebarItemRowView.Style.builtIn, .list, .chip, .tile, .icon])
    func everyLookDrawsTheGlyph(_ style: SidebarItemRowView.Style) throws {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        row.configure(try chiefInfo(), style: style)
        row.layoutSubtreeIfNeeded()
        #expect(row.icon.image != nil, "\(style): the Chief row draws no glyph")
    }
}
