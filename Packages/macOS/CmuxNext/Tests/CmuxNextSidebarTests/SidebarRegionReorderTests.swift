import AppKit
import Testing
@testable import CmuxNextSidebar

/// R77 for the item sections (coordinator 2026-10-04: the same in-place
/// reorder as the workspace list, one shared drag model): while an item or a
/// section is dragged, the region already shows it at the slot under the
/// pointer; on release the layout gets one move op and nothing jumps.
@MainActor @Suite struct SidebarRegionReorderTests {
    nonisolated static func item(_ id: String) -> LayoutItem { LayoutItem(id: LayoutItemID(id), ref: .app("app/\(id)")) }
    static let first = LayoutSection(id: LayoutSectionID("one"), title: "One", region: .top, items: ["a", "b", "c"].map(item))
    static let second = LayoutSection(id: LayoutSectionID("two"), title: "Two", region: .top, items: ["d"].map(item))
    static let metrics = SidebarRegionMetrics(rowHeight: 28, headerHeight: 24, inset: 8, sectionGap: 12, padding: 6,
                                             cardPadding: 4, tileMinWidth: 40, tileHeight: 40, tileGap: 4)

    static func layout(_ sections: [LayoutSection]) -> SidebarRegionLayout {
        SidebarRegionLayout.make(sections: sections, width: 240, look: .quiet, collapsed: [], metrics: metrics)
    }
    static func frame(_ id: String, in layout: SidebarRegionLayout) -> CGRect? {
        layout.rows.first { row in
            switch row.kind {
            case let .item(item, _), let .tile(item, _), let .chip(item, _): item == LayoutItemID(id)
            default: false
            }
        }?.frame
    }
    static func ids(_ sections: [LayoutSection]) -> [[String]] { sections.map { $0.items.map(\.id.rawValue) } }

    @Test func anItemOverAnotherTakesItsPlace() throws {
        let sections = [Self.first, Self.second]
        let display = Self.layout(sections)
        let a = try #require(Self.frame("a", in: display))
        let moved = try #require(SidebarRegionReorder.move(.item(LayoutItemID("c")), at: CGPoint(x: a.midX, y: a.midY), display: display, sections: sections))
        #expect(Self.ids(moved) == [["c", "a", "b"], ["d"]])
        // Over its own slot nothing changes (no back-and-forth).
        let again = Self.layout(moved)
        let c = try #require(Self.frame("c", in: again))
        #expect(SidebarRegionReorder.move(.item(LayoutItemID("c")), at: CGPoint(x: c.midX, y: c.midY), display: again, sections: moved) == nil)
        // Into the next section, over its item.
        let d = try #require(Self.frame("d", in: display))
        let across = try #require(SidebarRegionReorder.move(.item(LayoutItemID("a")), at: CGPoint(x: d.midX, y: d.midY), display: display, sections: sections))
        #expect(Self.ids(across) == [["b", "c"], ["a", "d"]])
    }

    @Test func aSectionOverAnotherTakesItsPlace() throws {
        let sections = [Self.first, Self.second]
        let display = Self.layout(sections)
        let a = try #require(Self.frame("a", in: display))
        let moved = try #require(SidebarRegionReorder.move(.section(LayoutSectionID("two")), at: CGPoint(x: a.midX, y: a.midY), display: display, sections: sections))
        #expect(moved.map(\.id.rawValue) == ["two", "one"])
    }

    @Test func theMoveBecomesOneDocumentOpThatSkipsHiddenItems() throws {
        // The document has a hidden item "h" the region does not show.
        var full = Self.first
        full.items.insert(Self.item("h"), at: 1)
        let document = SidebarLayoutDocument(sections: [full, Self.second])
        var shown = [Self.first, Self.second]
        shown[0].items = ["c", "a", "b"].map(Self.item)
        let op = try #require(SidebarRegionReorder.op(for: .item(LayoutItemID("c")), shown: shown, document: document))
        #expect(op == .itemMove(LayoutItemID("c"), section: LayoutSectionID("one"), index: 0))
        let result = try SidebarLayoutReducer.reduce(document, op).get()
        #expect(result.sections[0].items.map(\.id.rawValue) == ["c", "a", "h", "b"])
        let sectionOp = SidebarRegionReorder.op(for: .section(LayoutSectionID("two")), shown: [Self.second, Self.first], document: document)
        #expect(sectionOp == .sectionMove(LayoutSectionID("two"), region: .top, index: 0))
    }

    @Test func theRegionShowsTheNewOrderDuringTheDragAndSettlesWithoutAJump() throws {
        let region = SidebarRegionView(region: .top)
        let content = SidebarRegionView.Content(sections: [Self.first, Self.second], infos: [:], collapsed: [], look: .quiet,
                                                metrics: Self.metrics, drawsLines: true)
        region.update(content, width: 240)
        region.frame = NSRect(x: 0, y: 0, width: 240, height: region.layoutResult.height)
        var reorders: [(SidebarRegionDragSubject, [LayoutSection])] = []
        region.onReorder = { reorders.append(($0, $1)) }
        let c = try #require(Self.frame("c", in: region.layoutResult))
        let a = try #require(Self.frame("a", in: region.layoutResult))
        region.beginDrag(.item(LayoutItemID("c")), at: NSPoint(x: c.midX, y: c.midY))
        region.updateDrag(to: NSPoint(x: a.midX, y: a.midY))
        #expect(Self.ids(region.displayedSections) == [["c", "a", "b"], ["d"]])
        #expect(reorders.isEmpty)
        let slot = try #require(Self.frame("c", in: region.layoutResult))
        region.finishDrag()
        #expect(reorders.count == 1 && Self.ids(reorders.first?.1 ?? []) == [["c", "a", "b"], ["d"]])
        #expect(Self.frame("c", in: region.layoutResult) == slot)
    }
}
