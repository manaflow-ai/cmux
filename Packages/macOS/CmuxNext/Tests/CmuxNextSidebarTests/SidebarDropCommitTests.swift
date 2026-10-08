import AppKit
import Testing
@testable import CmuxNextSidebar

/// cx-odqn (Lawrence 2026-10-08 recording on nxdog71-v2): a workspace row
/// dragged onto the top band showed in both places (the card flew back
/// into the list while the band already showed the new pin), and the list
/// kept an empty slot at the row's old place while the row was held over
/// the band and after the drop. A tile dragged onto the list flew back
/// into the band, stayed there until its card landed, and then left an
/// empty band gap above the list. What a drop shows is derived from the
/// model and the drag (one outcome per drop): held over the band, the list
/// shows itself without the row; the card lands where the row goes.
/// Off-screen window only.
@MainActor @Suite struct SidebarDropCommitTests {
    private func sidebar() -> (SidebarView, NSWindow, () -> [SidebarIntent]) {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        var layout = SidebarLayoutDocument.defaults
        layout.sections.insert(SidebarPinDropTests.tiles, at: 1)
        model.layout = layout
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        let sidebar = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        window.contentView?.addSubview(sidebar)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (sidebar, window, { sent })
    }

    private func tileFrame(_ tile: String, in region: SidebarRegionView) throws -> CGRect {
        try #require(region.layoutResult.rows.first { SidebarRegionReorder.item(of: $0)?.0 == LayoutItemID(tile) }?.frame)
    }

    /// Drags local row `b` from the list over tile `t2` of the band.
    private func holdBOverTheBand(_ sidebar: SidebarView) throws {
        let list = sidebar.list
        let row = try #require(list.displayed.row(for: .workspace(id("b"))))
        let rowFrame = list.frame(for: row)
        list.beginDrag(SidebarListView.Press(key: .workspace(id("b")), point: NSPoint(x: rowFrame.midX, y: rowFrame.midY)))
        let t2 = try tileFrame("t2", in: sidebar.aboveRegion)
        list.updateDrag(windowPoint: sidebar.aboveRegion.convert(NSPoint(x: t2.minX + 1, y: t2.midY), to: nil))
        #expect(list.drag?.pinTarget != nil)
    }

    @Test func aRowHeldOverTheBandLeavesNoHoleInTheList() throws {
        let (sidebar, window, _) = sidebar()
        defer { window.close() }
        let list = sidebar.list
        let g2Before = try #require(list.displayed.row(for: .group(g2))).y
        let bHeight = try #require(list.displayed.row(for: .workspace(id("b")))).height
        try holdBOverTheBand(sidebar)
        #expect(list.displayed.row(for: .workspace(id("b"))) == nil, "the held row is not in the list: no empty slot at its old place")
        let g2Held = try #require(list.displayed.row(for: .group(g2))).y
        #expect(g2Held < g2Before - bHeight / 2, "the rows under it close up")
    }

    @Test func aPinDropLandsTheCardInTheBandNotBackInTheList() throws {
        let (sidebar, window, sent) = sidebar()
        defer { window.close() }
        let list = sidebar.list, region = sidebar.aboveRegion
        try holdBOverTheBand(sidebar)
        let lift = try #require(list.drag?.lift)
        let slot = region.convert(try tileFrame("t2", in: region), to: nil)
        list.finishDrag()
        #expect(sent().contains(.dropOnLayoutSection([id("b")], section: SidebarLayoutDocument.pinnedSectionID, index: 1)))
        let landed = list.convert(lift.frame, to: nil)
        #expect(abs(landed.midY - slot.midY) < 1, "the card lands on the band slot that takes the row (landed \(landed), slot \(slot))")
    }

    @Test func aTileHeldOverTheListLeavesTheBandAtOnce() throws {
        let (sidebar, window, _) = sidebar()
        defer { window.close() }
        let region = sidebar.aboveRegion
        let t1 = try tileFrame("t1", in: region)
        region.beginDrag(.item(LayoutItemID("t1")), at: NSPoint(x: t1.midX, y: t1.midY))
        let scroll = try #require(sidebar.list.enclosingScrollView)
        region.updateDrag(to: region.convert(scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil), from: nil))
        #expect(region.reorder?.dropsToList == true)
        #expect(!region.displayedSections.flatMap(\.items).contains { $0.id == LayoutItemID("t1") },
                "over the list the band shows itself without the tile (the drop's outcome)")
    }

    @Test func aTileDroppedOnTheListDoesNotFlyBackIntoTheBand() throws {
        let (sidebar, window, sent) = sidebar()
        defer { window.close() }
        let region = sidebar.aboveRegion
        let t1 = try tileFrame("t1", in: region)
        let t1InHost = sidebar.convert(t1, from: region)
        region.beginDrag(.item(LayoutItemID("t1")), at: NSPoint(x: t1.midX, y: t1.midY))
        let lift = try #require(region.reorder?.lift)
        let scroll = try #require(sidebar.list.enclosingScrollView)
        region.updateDrag(to: region.convert(scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil), from: nil))
        let held = lift.frame
        region.finishDrag()
        #expect(sent() == [.layout(.itemRemove(LayoutItemID("t1")))])
        #expect(lift.frame != t1InHost, "the card does not return to the tile's old slot")
        #expect(abs(lift.frame.midY - held.midY) < 1, "the card settles where it was dropped, over the list")
    }

    @Test func aBandHeightChangeRelaysTheSidebar() throws {
        let (sidebar, window, _) = sidebar()
        defer { window.close() }
        let region = sidebar.aboveRegion
        let bandHeight = sidebar.aboveScroll.frame.height
        region.reorderSections = region.displayedSections.map { section in
            var section = section
            section.items.removeAll { $0.id == LayoutItemID("t1") || $0.id == LayoutItemID("t2") || $0.id == LayoutItemID("t3") }
            return section
        }
        region.relayout(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.aboveScroll.frame.height < bandHeight, "a band that shrank gives its space back to the list (no gap)")
    }

    @Test func anEmptyMachineHeaderShowsAddButNoChevronOnHover() throws {
        var sections = fixture()
        sections[2].nodes = []
        let sidebar = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let header = try #require(sidebar.list.rowViews[.section(cloudSection)] as? SectionHeaderRowView)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        #expect(!header.addButton.isHidden, "+ makes a workspace on that machine")
        #expect(!header.showsChevron, "nothing to fold under a machine with no workspaces")
        let full = try #require(sidebar.list.rowViews[.section(local)] as? SectionHeaderRowView)
        full.isHovered = true
        full.layoutSubtreeIfNeeded()
        #expect(full.showsChevron, "a machine with workspaces still folds")
    }
}
