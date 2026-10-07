import AppKit
import Testing
@testable import CmuxNextSidebar

/// Drop-to-pin (PINNED-ITEMS-END-TO-END P2): a workspace row dragged from the
/// list onto the pinned tiles (or the top rows) asks the App to add it there
/// at the drop point, and the list keeps its order meanwhile; a workspace
/// tile dragged onto the list asks the App to take it out of the band. The
/// sidebar outlines the place that takes the drop. Off-screen window only.
@MainActor @Suite struct SidebarPinDropTests {
    static let metrics = SidebarRegionMetrics(rowHeight: 28, headerHeight: 24, inset: 8, sectionGap: 12, padding: 6,
                                             cardPadding: 4, tileMinWidth: 40, tileHeight: 40, tileGap: 4)
    nonisolated static func tile(_ id: String) -> LayoutItem { LayoutItem(id: LayoutItemID(id), ref: .workspace("s:ws_\(id)")) }
    static let tiles = LayoutSection(id: SidebarLayoutDocument.pinnedSectionID, region: .top, look: .builtIn,
                                     arrangement: SectionArrangement(layout: .grid, columns: 4), items: ["t1", "t2", "t3"].map(tile))

    // MARK: Where a drop lands (pure)

    private func band() -> SidebarRegionView {
        let region = SidebarRegionView(region: .top)
        region.update(SidebarRegionView.Content(sections: [Self.tiles], infos: [:], collapsed: [], look: .quiet, metrics: Self.metrics,
                                                drawsLines: true), width: 240)
        return region
    }

    private func frame(_ id: String, in region: SidebarRegionView) throws -> CGRect {
        try #require(region.layoutResult.rows.first { SidebarRegionReorder.item(of: $0)?.0 == LayoutItemID(id) }?.frame)
    }

    @Test func aDropLandsBeforeTheFirstTileItIsNotPast() throws {
        let region = band()
        let t1 = try frame("t1", in: region), t2 = try frame("t2", in: region), t3 = try frame("t3", in: region)
        func drop(_ point: CGPoint) -> SidebarRegionDrop? {
            SidebarRegionDrop.target(at: point, layout: region.layoutResult, sections: [Self.tiles], gap: Self.metrics.sectionGap)
        }
        #expect(drop(CGPoint(x: t1.minX + 1, y: t1.midY))?.index == 0)
        #expect(drop(CGPoint(x: t2.minX + 1, y: t2.midY))?.index == 1)
        #expect(drop(CGPoint(x: t3.maxX - 1, y: t3.midY))?.index == 3, "past the last tile goes last")
        #expect(drop(CGPoint(x: t1.midX, y: t1.midY))?.section == SidebarLayoutDocument.pinnedSectionID)
        #expect(drop(CGPoint(x: t1.midX, y: t1.maxY + 200)) == nil, "below the band takes nothing")
    }

    // MARK: The drags

    private func sidebar() -> (SidebarView, NSWindow, () -> [SidebarIntent]) {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        var layout = SidebarLayoutDocument.defaults
        layout.sections.insert(Self.tiles, at: 1)
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

    @Test func aRowDroppedOnTheTilesIsPinnedThereAndTheListKeepsItsOrder() throws {
        let (sidebar, window, sent) = sidebar()
        defer { window.close() }
        let list = sidebar.list, region = sidebar.aboveRegion
        let row = try #require(list.displayed.row(for: .workspace(id("b"))))
        let rowFrame = list.frame(for: row)
        list.beginDrag(SidebarListView.Press(key: .workspace(id("b")), point: NSPoint(x: rowFrame.midX, y: rowFrame.midY)))
        let t2 = try frame("t2", in: region)
        list.updateDrag(windowPoint: region.convert(NSPoint(x: t2.minX + 1, y: t2.midY), to: nil))
        #expect(list.drag?.pinTarget?.section == SidebarLayoutDocument.pinnedSectionID)
        #expect(list.drag?.pinTarget?.index == 1)
        #expect(sidebar.dropOutlineView?.ring.rect != nil, "the tiles are outlined")
        list.finishDrag()
        #expect(sent().contains(.dropOnLayoutSection([id("b")], section: SidebarLayoutDocument.pinnedSectionID, index: 1)))
        #expect(!sent().contains { if case .reorder = $0 { true } else { false } }, "the list order does not change")
    }

    @Test func aTileDroppedOnTheListLeavesTheBand() throws {
        let (sidebar, window, sent) = sidebar()
        defer { window.close() }
        let region = sidebar.aboveRegion
        let t1 = try frame("t1", in: region)
        region.beginDrag(.item(LayoutItemID("t1")), at: NSPoint(x: t1.midX, y: t1.midY))
        let scroll = try #require(sidebar.list.enclosingScrollView)
        let overList = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        region.updateDrag(to: region.convert(overList, from: nil))
        #expect(region.reorder?.dropsToList == true)
        region.finishDrag()
        #expect(sent() == [.layout(.itemRemove(LayoutItemID("t1")))])
    }

    @Test func anAppTileDroppedOnTheListStaysInTheBand() throws {
        let (sidebar, window, sent) = sidebar()
        defer { window.close() }
        let region = sidebar.aboveRegion
        let home = try #require(sidebar.model.layout.firstItem(with: SidebarLayoutDocument.homeRef))
        let homeFrame = try #require(region.layoutResult.rows.first { SidebarRegionReorder.item(of: $0)?.0 == home.id }?.frame)
        region.beginDrag(.item(home.id), at: NSPoint(x: homeFrame.midX, y: homeFrame.midY))
        let scroll = try #require(sidebar.list.enclosingScrollView)
        region.updateDrag(to: region.convert(scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil), from: nil))
        #expect(region.reorder?.dropsToList == false)
        region.cancelDrag()
        #expect(!sent().contains { if case .layout(.itemRemove) = $0 { true } else { false } })
    }
}
