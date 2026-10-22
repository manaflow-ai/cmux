import CoreGraphics
@testable import CmuxNextTabs
import Testing

/// The vertical tab list's rows and drops (Leo 2026-10-20, vertical tabs like Edge's and Chrome's):
/// pinned tabs as tiles, each group's tabs under its header and hidden while it is collapsed, and a
/// dragged tab's drop turned into the strip's intents.
@MainActor @Suite struct VerticalTabListLayoutTests {
    static let work = TabGroupID("work"), later = TabGroupID("later")

    /// p1 p2 (pinned) | a | Work: w1 w2 | Later (collapsed): l1 | b
    static func model() -> TabStripModel {
        func tab(_ id: String, pinned: Bool = false, group: TabGroupID? = nil) -> TabItem {
            TabItem(id: TabID(id), title: id, isPinned: pinned, groupID: group)
        }
        return TabStripModel(tabs: [tab("p1", pinned: true), tab("p2", pinned: true), tab("a"), tab("w1", group: work), tab("w2", group: work),
                                    tab("l1", group: later), tab("b")],
                             groups: [TabGroupItem(id: work, name: "Work", colorToken: .blue),
                                      TabGroupItem(id: later, name: "Later", colorToken: .red, isCollapsed: true)],
                             selectedID: TabID("a"))
    }

    static func layout(_ model: TabStripModel = model(), iconsOnly: Bool = false) -> VerticalTabListLayout {
        VerticalTabListLayout(tabs: model.orderedTabs, groups: model.groups, showsNewTab: true, iconsOnly: iconsOnly, width: 240,
                              metrics: VerticalTabListMetrics())
    }

    static func row(_ layout: VerticalTabListLayout, _ kind: VerticalTabListLayout.RowKind) throws -> VerticalTabListLayout.Row {
        try #require(layout.rows.first { $0.kind == kind }, "no row \(kind)")
    }

    @Test func pinnedTilesThenGroupedRowsThenNewTab() throws {
        let layout = Self.layout()
        #expect(layout.rows.map(\.kind) == [
            .pinned(TabID("p1")), .pinned(TabID("p2")), .separator, .tab(TabID("a")), .groupHeader(Self.work), .tab(TabID("w1")),
            .tab(TabID("w2")), .groupHeader(Self.later), .tab(TabID("b")), .newTab,
        ], "a collapsed group shows its header only")
        let p1 = try Self.row(layout, .pinned(TabID("p1"))), p2 = try Self.row(layout, .pinned(TabID("p2")))
        #expect(p1.frame.minY == p2.frame.minY && p2.frame.minX > p1.frame.maxX, "pinned tabs share a line of tiles")
        let a = try Self.row(layout, .tab(TabID("a"))), w1 = try Self.row(layout, .tab(TabID("w1")))
        #expect(w1.frame.minX == a.frame.minX + VerticalTabListMetrics().groupIndent, "a group's tabs sit in from the others")
        #expect(w1.group == Self.work && a.group == nil)
        let w2 = try Self.row(layout, .tab(TabID("w2")))
        let line = try #require(layout.groupLines.first)
        #expect(layout.groupLines.count == 1, "a collapsed group draws no line")
        #expect(line.group == Self.work && line.frame.minY <= w1.frame.minY && line.frame.maxY == w2.frame.maxY,
                "one line joins the group's tabs")
        #expect(line.frame.maxX <= w1.frame.minX)
        let newTab = try Self.row(layout, .newTab)
        #expect(layout.contentHeight > newTab.frame.maxY)
    }

    @Test func iconsOnlyStacksTheTilesAndDropsTheIndent() throws {
        let layout = Self.layout(iconsOnly: true)
        let p1 = try Self.row(layout, .pinned(TabID("p1"))), p2 = try Self.row(layout, .pinned(TabID("p2")))
        #expect(p2.frame.minY > p1.frame.maxY, "one column of tiles")
        let a = try Self.row(layout, .tab(TabID("a"))), w1 = try Self.row(layout, .tab(TabID("w1")))
        #expect(w1.frame.minX == a.frame.minX)
        #expect(try Self.row(layout, .groupHeader(Self.work)).frame.height == VerticalTabListMetrics().iconsOnlyHeaderHeight)
    }

    @Test func rowAtAPointFindsTilesAndRows() throws {
        let layout = Self.layout()
        let w2 = try Self.row(layout, .tab(TabID("w2")))
        #expect(layout.row(at: CGPoint(x: 4, y: w2.frame.midY))?.kind == .tab(TabID("w2")), "the whole band of a row hits it")
        let p2 = try Self.row(layout, .pinned(TabID("p2")))
        #expect(layout.row(at: CGPoint(x: p2.frame.midX, y: p2.frame.midY))?.kind == .pinned(TabID("p2")))
        #expect(layout.row(at: CGPoint(x: 10, y: layout.contentHeight + 40)) == nil)
    }

    @Test func slotsFollowThePointerAroundGroups() throws {
        let layout = Self.layout()
        let b = try #require(Self.model().tab(TabID("b")))
        func slot(_ kind: VerticalTabListLayout.RowKind, _ fraction: CGFloat) throws -> VerticalTabListLayout.Slot {
            let frame = try Self.row(layout, kind).frame
            return layout.slot(at: CGPoint(x: frame.midX, y: frame.minY + frame.height * fraction), dragging: b)
        }
        // Indices: p1 0, p2 1, a 2, w1 3, w2 4, l1 5, b 6.
        #expect(try slot(.tab(TabID("a")), 0.25).index == 2)
        #expect(try slot(.tab(TabID("a")), 0.25).group == nil)
        #expect(try slot(.groupHeader(Self.work), 0.25).index == 3 && slot(.groupHeader(Self.work), 0.25).group == nil,
                "above an open header's middle is before the group")
        #expect(try slot(.groupHeader(Self.work), 0.75).index == 3 && slot(.groupHeader(Self.work), 0.75).group == Self.work,
                "below it is the group's first place")
        #expect(try slot(.tab(TabID("w1")), 0.75).index == 4 && slot(.tab(TabID("w1")), 0.75).group == Self.work)
        #expect(try slot(.tab(TabID("w2")), 0.75).index == 5 && slot(.tab(TabID("w2")), 0.75).group == Self.work,
                "the lower half of a group's last tab is still in the group")
        #expect(try slot(.groupHeader(Self.later), 0.25).index == 5 && slot(.groupHeader(Self.later), 0.25).group == nil)
        #expect(try slot(.groupHeader(Self.later), 0.75).index == 6 && slot(.groupHeader(Self.later), 0.75).group == nil,
                "a collapsed group takes no drop")
        let end = layout.slot(at: CGPoint(x: 20, y: layout.contentHeight + 100), dragging: b)
        #expect(end.index == 7 && end.group == nil)
        let pinned = try #require(Self.model().tab(TabID("p1")))
        #expect(layout.slot(at: CGPoint(x: 20, y: layout.contentHeight + 100), dragging: pinned).index == 2,
                "a pinned tab stays among the pinned tiles")
    }

    // MARK: Drops

    static func drop(_ model: TabStripModel = model()) -> VerticalTabDrop {
        VerticalTabDrop(tabs: model.orderedTabs, selection: model.multiSelection, hasGroups: !model.groups.isEmpty)
    }

    @Test func dropsReorderWithinTheSameGroupOrNone() {
        let drop = Self.drop()
        #expect(drop.intent(dropping: TabID("b"), at: 2, in: nil) == .reorder(TabID("b"), from: 6, to: 2))
        #expect(drop.intent(dropping: TabID("a"), at: 3, in: nil) == nil, "its own place")
        #expect(drop.intent(dropping: TabID("a"), at: 0, in: nil) == nil, "an unpinned tab stays after the pinned ones")
        #expect(drop.intent(dropping: TabID("w2"), at: 3, in: Self.work) == .reorder(TabID("w2"), from: 4, to: 3))
    }

    @Test func dropsJoinAndLeaveGroups() {
        let drop = Self.drop()
        #expect(drop.intent(dropping: TabID("a"), at: 4, in: Self.work) == .addToGroup(TabID("a"), Self.work, index: 3))
        #expect(drop.intent(dropping: TabID("w1"), at: 7, in: nil) == .removeFromGroup(TabID("w1"), index: 6))
        #expect(drop.intent(dropping: TabID("w2"), at: 5, in: nil) == .removeFromGroup(TabID("w2"), index: 4),
                "dropped just after its group, it leaves the group in place")
    }

    @Test func pinnedDropsStayPinned() {
        let drop = Self.drop()
        #expect(drop.intent(dropping: TabID("p1"), at: 6, in: nil) == .reorder(TabID("p1"), from: 0, to: 1))
        #expect(drop.intent(dropping: TabID("p2"), at: 0, in: nil) == .reorder(TabID("p2"), from: 1, to: 0))
    }

    @Test func aSelectionMovesTogetherWhenThereAreNoGroups() {
        let model = TabStripModel(tabs: (0..<6).map { TabItem(id: TabID("t\($0)"), title: "t\($0)") }, selectedID: TabID("t1"))
        _ = model.click(TabID("t3"), .toggle)
        let drop = Self.drop(model)
        #expect(drop.movesSelection(TabID("t1")) && !drop.movesSelection(TabID("t2")))
        #expect(drop.intent(dropping: TabID("t1"), at: 6, in: nil) == .reorderTabs(["t0", "t2", "t4", "t5", "t1", "t3"].map { TabID($0) }))
        #expect(drop.intent(dropping: TabID("t1"), at: 1, in: nil) == .reorderTabs(["t0", "t1", "t3", "t2", "t4", "t5"].map { TabID($0) }))
    }
}
