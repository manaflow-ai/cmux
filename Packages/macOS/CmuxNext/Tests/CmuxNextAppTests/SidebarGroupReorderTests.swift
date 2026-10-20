import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-19 (u2455): reordering groups by dragging needs a rule
/// that uses both the top and the bottom of the dragged group. Its bottom
/// passing the middle of the block below moves it down; its top passing the
/// middle of the block above moves it up; a margin keeps it from flickering.
@Suite struct SidebarGroupReorderTests {
    /// Blocks of `heights`, stacked from y 0 with no spacing.
    static func reorder(_ heights: [CGFloat], shift: CGFloat) -> SidebarGroupReorder {
        var y: CGFloat = 0
        var blocks: [ClosedRange<CGFloat>] = []
        for height in heights {
            blocks.append(y...(y + height))
            y += height
        }
        return SidebarGroupReorder(blocks: blocks, shift: shift)
    }

    /// The card `height` tall, dragged `dy` from its rest place in the gap at `current`.
    static func index(_ r: SidebarGroupReorder, height: CGFloat, current: Int, dy: CGFloat) -> Int {
        let top = (current == 0 ? 0 : r.blocks[current - 1].upperBound) + dy
        return r.index(top: top, bottom: top + height, current: current)
    }

    @Test func aCardAtRestStays() {
        let r = Self.reorder([28, 28, 28], shift: 28)
        for current in 0...3 { #expect(Self.index(r, height: 28, current: current, dy: 0) == current) }
    }

    /// Short card, short neighbours: the bottom edge must pass the next block's middle plus the margin.
    @Test func aShortGroupMovesDownWhenItsBottomPassesTheMiddleBelow() {
        let r = Self.reorder([28, 28, 28], shift: 28)
        let margin = SidebarGroupReorder.hysteresis(for: 28) // 5.6
        #expect(Self.index(r, height: 28, current: 1, dy: 14 + margin - 1) == 1)
        #expect(Self.index(r, height: 28, current: 1, dy: 14 + margin + 1) == 2)
        #expect(Self.index(r, height: 28, current: 1, dy: -(14 + margin - 1)) == 1)
        #expect(Self.index(r, height: 28, current: 1, dy: -(14 + margin + 1)) == 0)
    }

    /// A tall (expanded) group moves down as soon as its bottom reaches a short neighbour's middle,
    /// long before its header would.
    @Test func aTallGroupMovesByItsBottomEdge() {
        let r = Self.reorder([28, 28, 28], shift: 200)
        #expect(Self.index(r, height: 200, current: 1, dy: 21) == 2)
        #expect(Self.index(r, height: 200, current: 1, dy: -21) == 0)
    }

    /// A short (collapsed) group needs to reach a tall neighbour's middle.
    @Test func aShortGroupNeedsATallNeighboursMiddle() {
        let r = Self.reorder([28, 200, 28], shift: 28)
        #expect(Self.index(r, height: 28, current: 1, dy: 60) == 1)
        #expect(Self.index(r, height: 28, current: 1, dy: 100 + 8 + 1) == 2)
        let up = Self.reorder([200, 28, 28], shift: 28)
        #expect(Self.index(up, height: 28, current: 1, dy: -60) == 1)
        #expect(Self.index(up, height: 28, current: 1, dy: -(100 + 8 + 1)) == 0)
    }

    /// Mixed: a fast drag passes several blocks of different heights in one move.
    @Test func aFastDragPassesSeveralBlocks() {
        let r = Self.reorder([28, 120, 28, 60, 28], shift: 28)
        // From the top gap, the bottom (258) passes the middle of the 60-pt block drawn below the gap (204...264).
        #expect(Self.index(r, height: 28, current: 0, dy: 230) == 4)
        #expect(Self.index(r, height: 28, current: 0, dy: 190) == 3)
        // And back up from the end: the top passes the middle of the 120-pt block (28...148, mid 88).
        #expect(Self.index(r, height: 28, current: 5, dy: -(264 - 70)) == 1)
    }

    /// Once moved, wiggling around the boundary that moved it never moves it back.
    @Test func noFlickerAtTheBoundary() {
        let r = Self.reorder([28, 28, 28], shift: 28)
        let margin = SidebarGroupReorder.hysteresis(for: 28)
        // Moved down to 2 with the card's top at 28 + 14 + margin + 1 (gap now after block 1).
        let top: CGFloat = 28 + 14 + margin + 1
        #expect(r.index(top: top - 28, bottom: top, current: 1) == 1) // the card at rest-ish: no move
        #expect(r.index(top: top, bottom: top + 28, current: 1) == 2)
        for wiggle in stride(from: CGFloat(-2 * margin + 1), through: 3, by: 1) {
            #expect(r.index(top: top + wiggle, bottom: top + wiggle + 28, current: 2) == 2, "wiggle \(wiggle)")
        }
    }

    @Test func theGapIndexAndItsProbe() {
        let r = Self.reorder([20, 60, 20], shift: 40)
        #expect(r.index(ofGapAt: 0) == 0)
        #expect(r.index(ofGapAt: 20) == 1)
        #expect(r.index(ofGapAt: 80) == 2)
        #expect(r.index(ofGapAt: 100) == 3)
        #expect(r.probeY(for: 0) == 0.5)
        #expect(r.probeY(for: 1) == 19.5)
        #expect(r.probeY(for: 3) == 99.5)
    }

    /// A group is one block with its members and their tab rows; loose rows and headers are their own.
    @Test func blocksGroupHeadersWithTheirMembers() {
        let g = GroupID("g"), w = WorkspaceID("w"), m = WorkspaceID("m")
        func row(_ key: SidebarRowKey, _ y: CGFloat, group: GroupID? = nil) -> SidebarRow {
            SidebarRow(key: key, y: y, height: 20, section: .pinned, group: group, siblingIndex: 0, parentIndex: nil,
                       isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
        }
        let rows = [
            row(.section(.pinned), 0),
            row(.workspace(w), 20),
            row(.tab(w, TabID("t")), 40),
            row(.group(g), 60, group: g),
            row(.workspace(m), 80, group: g),
            row(.tab(m, TabID("u")), 100, group: g),
            row(.workspace(WorkspaceID("x")), 120),
        ]
        #expect(SidebarGroupReorder.blocks(of: rows) == [0...20, 20...60, 60...120, 120...140])
    }
}
