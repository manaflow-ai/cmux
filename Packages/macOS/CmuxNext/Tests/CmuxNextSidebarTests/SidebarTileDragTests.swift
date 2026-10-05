import AppKit
import Testing
@testable import CmuxNextSidebar

/// Direct drag (Leo 2026-10-05): tiles drag at any time, with no edit mode.
/// A tile's neighbors sit beside it, so its lifted card follows the pointer
/// sideways as well as up and down, and the tile it covers makes way. List
/// rows and section headers keep the vertical-only card.
@MainActor @Suite struct SidebarTileDragTests {
    nonisolated static func item(_ id: String) -> LayoutItem { LayoutItem(id: LayoutItemID(id), ref: .app("app/\(id)")) }
    static let tiles = LayoutSection(id: LayoutSectionID("tiles"), region: .top, look: .builtIn,
                                     arrangement: SectionArrangement(layout: .tiles, columns: 4), items: ["a", "b", "c", "d"].map(item))
    static let list = LayoutSection(id: LayoutSectionID("list"), title: "List", region: .top, items: ["e", "f"].map(item))
    static let metrics = SidebarRegionMetrics(rowHeight: 28, headerHeight: 24, inset: 8, sectionGap: 12, padding: 6,
                                             cardPadding: 4, tileMinWidth: 40, tileHeight: 40, tileGap: 4)

    private func region() -> SidebarRegionView {
        let region = SidebarRegionView(region: .top)
        let content = SidebarRegionView.Content(sections: [Self.tiles, Self.list], infos: [:], collapsed: [], look: .quiet,
                                                metrics: Self.metrics, drawsLines: true)
        region.update(content, width: 240)
        region.frame = NSRect(x: 0, y: 0, width: 240, height: region.layoutResult.height)
        return region
    }

    private func frame(_ id: String, in region: SidebarRegionView) -> CGRect? {
        region.layoutResult.rows.first { SidebarRegionReorder.item(of: $0)?.0 == LayoutItemID(id) }?.frame
    }

    private func ids(_ sections: [LayoutSection]) -> [[String]] { sections.map { $0.items.map(\.id.rawValue) } }

    @Test func onlyAnItemOfAFlowedSectionFollowsOnBothAxes() {
        let sections = [Self.tiles, Self.list]
        #expect(SidebarRegionDrag.followsBothAxes(.item(LayoutItemID("b")), sections: sections, look: .quiet))
        #expect(!SidebarRegionDrag.followsBothAxes(.item(LayoutItemID("e")), sections: sections, look: .quiet))
        #expect(!SidebarRegionDrag.followsBothAxes(.section(Self.tiles.id), sections: sections, look: .quiet))
    }

    @Test func aTileDraggedSidewaysTakesTheSlotUnderItAndTheCardFollowsThePointer() throws {
        let region = region()
        var reorders: [[LayoutSection]] = []
        region.onReorder = { reorders.append($1) }
        let a = try #require(frame("a", in: region))
        let d = try #require(frame("d", in: region))
        #expect(a.minY == d.minY, "one line of tiles")

        region.beginDrag(.item(LayoutItemID("d")), at: NSPoint(x: d.midX, y: d.midY))
        region.updateDrag(to: NSPoint(x: a.midX, y: a.midY))
        let card = try #require(region.reorder?.lift.frame)
        #expect(abs(card.midX - a.midX) < 0.5, "the card moved sideways with the pointer")
        #expect(abs(card.midY - d.midY) < 0.5)
        #expect(ids(region.displayedSections) == [["d", "a", "b", "c"], ["e", "f"]])

        region.finishDrag()
        #expect(reorders.count == 1 && ids(reorders.first ?? []) == [["d", "a", "b", "c"], ["e", "f"]])
    }

    @Test func aListRowCardStaysInItsColumn() throws {
        let region = region()
        let e = try #require(frame("e", in: region))
        let f = try #require(frame("f", in: region))
        region.beginDrag(.item(LayoutItemID("f")), at: NSPoint(x: f.midX, y: f.midY))
        region.updateDrag(to: NSPoint(x: f.midX + 60, y: e.midY))
        let card = try #require(region.reorder?.lift.frame)
        #expect(card.minX == f.minX, "a list row only moves up and down")
        #expect(ids(region.displayedSections) == [["a", "b", "c", "d"], ["f", "e"]])
        region.cancelDrag()
    }
}
