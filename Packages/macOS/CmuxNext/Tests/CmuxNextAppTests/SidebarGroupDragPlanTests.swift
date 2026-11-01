import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// The group drag's pure geometry (`SidebarGroupDragPlan`; plans/cmux-next/sidebar-owner.md, "Group drag: design
/// for the rewrite"): the slot is a step function of the card's centre alone, the card is cut to its header and
/// three rows, and the drawn list is one function of (base, slot, gap).
@Suite struct SidebarGroupDragPlanTests {
    static func row(_ key: SidebarRowKey, _ y: CGFloat, height: CGFloat = 20, group: GroupID? = nil, index: Int = 0) -> SidebarRow {
        SidebarRow(key: key, y: y, height: height, section: .pinned, group: group, siblingIndex: index, parentIndex: nil,
                   isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
    }

    /// The base of a list without the dragged group: a section header, a loose row, a group of three and two loose
    /// rows, 6 pt apart. Blocks: 0...20, 26...46, 52...118, 124...144, 150...170.
    static let base: [SidebarRow] = {
        let g = GroupID("g")
        return [
            row(.section(.pinned), 0),
            row(.workspace(WorkspaceID("a")), 26, index: 0),
            row(.group(g), 52, group: g, index: 1),
            row(.workspace(WorkspaceID("g1")), 74, group: g),
            row(.workspace(WorkspaceID("g2")), 98, group: g),
            row(.workspace(WorkspaceID("b")), 124, index: 2),
            row(.workspace(WorkspaceID("c")), 150, index: 3),
        ]
    }()

    /// The dragged group stood after `a` (its top at 52 before it lifted), its card cut to 60 pt.
    static func plan(allowed: [Bool]? = nil) -> SidebarGroupDragPlan {
        SidebarGroupDragPlan(blocks: SidebarGroupDragPlan.blocks(of: base), groupTop: 52, card: 60, lead: 6, trail: 6, allowed: allowed)
    }

    @Test func theBlocksAreTheTopLevelThings() {
        #expect(Self.plan().blocks.map(\.range) == [0...20, 26...46, 52...118, 124...144, 150...170])
        #expect(Self.plan().blocks.map(\.head.key) == [.section(.pinned), .workspace(WorkspaceID("a")), .group(GroupID("g")),
                                                       .workspace(WorkspaceID("b")), .workspace(WorkspaceID("c"))])
    }

    @Test func blocksKeepMembersWithTheirHead() {
        let g = GroupID("g"), w = WorkspaceID("w"), m = WorkspaceID("m")
        let rows = [
            Self.row(.section(.pinned), 0),
            Self.row(.workspace(w), 20),
            Self.row(.group(g), 60, group: g),
            Self.row(.workspace(m), 80, group: g),
            Self.row(.workspace(WorkspaceID("x")), 120),
        ]
        #expect(SidebarGroupDragPlan.blocks(of: rows).map(\.range) == [0...20, 20...40, 60...100, 120...140])
    }

    /// The card's centre maps to its top in base space: where the group stood (top 52), the slot is where it came from.
    @Test func theSlotAtLiftIsTheOrigin() {
        let plan = Self.plan()
        #expect(plan.origin == 2)
        #expect(plan.slot(cardCentre: 52 + 30) == 2)
    }

    /// Both edges of every block: just above a block's middle the card stands before it, just below after it.
    @Test(arguments: 0..<5)
    func eachBlocksMiddleIsTheBoundary(index: Int) {
        let plan = Self.plan()
        let block = plan.blocks[index].range
        let mid = (block.lowerBound + block.upperBound) / 2
        #expect(plan.slot(cardCentre: mid - 0.01 + 30) == index)
        #expect(plan.slot(cardCentre: mid + 0.01 + 30) == index + 1)
    }

    /// Monotonic in y, and the same y always gives the same slot, whatever came before.
    @Test func theSlotIsAStepFunctionOfThePointerAlone() {
        let plan = Self.plan()
        var last = 0
        var seen: [CGFloat: Int] = [:]
        for y in stride(from: CGFloat(-50), through: 250, by: 0.5) {
            let slot = plan.slot(cardCentre: y)
            #expect(slot >= last, "slot \(slot) at \(y) after \(last)")
            last = slot
            seen[y] = slot
        }
        for y in stride(from: CGFloat(250), through: -50, by: -0.5) {
            #expect(plan.slot(cardCentre: y) == seen[y], "going up, \(y) gives another slot")
        }
        for _ in 0..<10 { #expect(plan.slot(cardCentre: 99) == plan.slot(cardCentre: 99)) }
        #expect(plan.slot(cardCentre: -1000) == 0)
        #expect(plan.slot(cardCentre: 1000) == 5)
    }

    /// A slot the drop cannot take gives the nearest that can (the upper on a tie); the origin always can.
    @Test func aRefusedSlotGivesTheNearestAccepted() {
        let plan = Self.plan(allowed: [false, true, false, false, true, false])
        #expect(plan.allowed == [false, true, true, false, true, false]) // the origin (2) takes it
        #expect(plan.slot(cardCentre: -100) == 1)
        let mid3 = (plan.blocks[2].range.lowerBound + plan.blocks[2].range.upperBound) / 2 // raw slot 3 just past it
        #expect(plan.slot(cardCentre: mid3 + 1 + 30) == 2) // 3 refused: 2 and 4 tie, the upper wins
        #expect(plan.slot(cardCentre: 1000) == 4)
    }

    @Test func aTallGroupsCardIsItsHeaderAndThreeRows() {
        let rows: [ClosedRange<CGFloat>] = [100...128, 130...158, 160...188, 190...218, 220...248, 250...278]
        #expect(SidebarGroupDragPlan.cardHeight(rows: rows, top: 100, full: 178) == 118)
        // Header and three rows: whole.
        #expect(SidebarGroupDragPlan.cardHeight(rows: Array(rows.prefix(4)), top: 100, full: 118) == 118)
        #expect(SidebarGroupDragPlan.cardHeight(rows: [100...128], top: 100, full: 28) == 28)
        // Rows with no height (a row closing its slot) do not count.
        #expect(SidebarGroupDragPlan.cardHeight(rows: [100...128, 128...128, 130...158, 160...188, 190...218], top: 100, full: 118) == 118)
    }

    /// The gap is the cut card and the spacing below it, never the whole group.
    @Test func theGapIsTheCardsHeight() {
        #expect(Self.plan().gap == 66)
    }

    /// Rows above the slot stay; rows at and below it move down by the gap; the gap is marked at the slot's top.
    @Test(arguments: 0...5)
    func theLayoutShiftsOnlyTheRowsAtAndBelowTheSlot(slot: Int) {
        let plan = Self.plan()
        let base = SidebarLayout(rows: Self.base, totalHeight: 170, gapY: nil, gapHeight: 0, gapShift: 0)
        let layout = plan.layout(base, slot: slot)
        let top = plan.top(of: slot)
        #expect(layout.rows.map(\.key) == base.rows.map(\.key))
        for (drawn, row) in zip(layout.rows, base.rows) {
            #expect(drawn.y == (row.y >= top ? row.y + plan.gap : row.y), "\(row.key) at slot \(slot)")
        }
        #expect(layout.gapY == top && layout.gapShift == plan.gap && layout.gapHeight == 0)
        #expect(layout.totalHeight == 170 + plan.gap)
    }

    /// The landing frame's top: the slot's block top, or past the last block by the spacing above the card.
    @Test func theSlotsTopIsWhereTheCardLands() {
        let plan = Self.plan()
        #expect((0...4).map { plan.top(of: $0) } == [0, 26, 52, 124, 150])
        #expect(plan.top(of: 5) == 176)
    }
}
