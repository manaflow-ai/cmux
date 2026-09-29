import CoreGraphics
import Testing
@testable import CmuxNextTabs

/// Entries of 100 pt tabs and 20 pt chips; x is recomputed by the math.
private func entry(_ id: String, _ width: CGFloat = 100, group: String? = nil, chip: Bool = false, collapsed: Bool = false) -> TabLayoutSlot {
    TabLayoutSlot(
        id: chip ? .groupChip(TabGroupID(group ?? "")) : TabID(id),
        x: 0,
        width: collapsed ? 0 : width,
        isPinned: false,
        groupID: group.map { TabGroupID($0) },
        isGroupChip: chip,
        isCollapsed: collapsed
    )
}

@Suite("Group boundary math")
struct GroupBoundaryTests {
    // a | [chip g] b c | d     edges: 0, 100, 120, 220, 320, 420
    private let entries = [entry("a"), entry("", 20, group: "g", chip: true), entry("b", group: "g"), entry("c", group: "g"), entry("d")]

    private func resolve(_ x: CGFloat, current: TabGroupID? = nil) -> TabGroupDropResolution {
        TabGroupDropMath.resolveTab(entries: entries, start: 0, draggedMinX: x, currentGroup: current, hysteresis: 30)
    }

    @Test func beforeTheChipIsOutside() {
        #expect(resolve(95) == TabGroupDropResolution(index: 1, groupID: nil))
    }

    @Test func rightAfterTheChipJoinsAsFirstMember() {
        #expect(resolve(125) == TabGroupDropResolution(index: 1, groupID: "g"))
    }

    @Test func betweenMembersJoins() {
        #expect(resolve(215) == TabGroupDropResolution(index: 2, groupID: "g"))
    }

    @Test func trailingEdgeKeepsMembershipWithinHysteresis() {
        // Nearest edge is 320 (after c). A member stays until 30 pt past it.
        #expect(resolve(340, current: "g").groupID == "g")
        #expect(resolve(355, current: "g").groupID == nil)
    }

    @Test func trailingEdgeJoinsOnlyWellInsideTheGroup() {
        // An outsider joins only when its leading edge is 30 pt before the edge.
        #expect(resolve(300, current: nil).groupID == nil)
        #expect(resolve(285, current: nil).groupID == "g")
        #expect(resolve(285, current: nil).index == 3)
    }

    @Test func positionsInsideCollapsedGroupsAreSkipped() {
        let collapsed = [entry("a"), entry("", 20, group: "g", chip: true), entry("b", group: "g", collapsed: true), entry("c", group: "g", collapsed: true), entry("d")]
        // Edges: 0, 100, 120, 120, 120, 220. Only 0, 100 and the edge after c (120) are valid.
        let hit = TabGroupDropMath.resolveTab(entries: collapsed, start: 0, draggedMinX: 118, currentGroup: nil, hysteresis: 30)
        #expect(hit == TabGroupDropResolution(index: 3, groupID: nil))
    }

    @Test func unitsCombineChipAndMembers() {
        let units = TabGroupDropMath.units(entries)
        #expect(units == [.init(width: 100, tabCount: 1), .init(width: 220, tabCount: 2), .init(width: 100, tabCount: 1)])
    }

    @Test func groupDragLandsBetweenUnitsOnly() {
        // Dragging a group near x = 330 lands after the g block: 1 + 2 tabs before it.
        let hit = TabGroupDropMath.resolveGroup(entries: entries, start: 0, draggedMinX: 330)
        #expect(hit.unitIndex == 2)
        #expect(hit.tabIndex == 3)
        #expect(TabGroupDropMath.resolveGroup(entries: entries, start: 0, draggedMinX: 150).tabIndex == 1)
    }
}
