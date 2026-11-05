import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// REOPEN-F7 part A (whole stall stacks after a reopen, cmux18 job cea96828): the first window's display pass rasterized
/// icon images (`-[NSImageView layout]`, `NSImage CGImageForProposedRect`). A destination row (Home, the band's rows)
/// made a new glyph image on every layout pass, so each pass laid its icon view out and drew it again. A layout that
/// changes nothing the glyph shows keeps the image it has.
@MainActor
@Suite struct SidebarItemGlyphStaysTests {
    static let home = LayoutItemID("itm_home")

    @Test(arguments: [SidebarItemRowView.Style.builtIn, .list, .tile, .chip])
    func aLayoutThatChangesNothingKeepsTheGlyphImage(_ style: SidebarItemRowView.Style) throws {
        let item = LayoutItem(id: Self.home, ref: SidebarLayoutDocument.homeRef)
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item])])
        let info = try #require(SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 0)[item.id])
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 52))
        row.configure(info, style: style)
        row.layoutSubtreeIfNeeded()
        let first = try #require(row.icon.image, "\(style): the row shows no glyph")
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        #expect(row.icon.image === first, "\(style): a layout that changed nothing made a new glyph image")
        // A new size is a new glyph.
        row.setFrameSize(NSSize(width: 56, height: 52))
        row.configure(info, style: .tile)
        row.layoutSubtreeIfNeeded()
        #expect(row.icon.image != nil)
    }
}
