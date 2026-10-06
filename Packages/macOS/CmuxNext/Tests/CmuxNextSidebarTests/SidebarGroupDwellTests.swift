import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// Drag to group (Leo, 2026-10-05): the pointer's place in the row under it
/// decides. The outer quarters reorder; the middle half groups, but only
/// after the pointer rests there, and it holds until the pointer leaves a
/// wider band, so the two never flicker.
@Suite struct SidebarGroupDwellTests {
    let layout = SidebarLayout.make(sections: fixture(), metrics: .standard)

    func y(_ key: SidebarRowKey, _ fraction: CGFloat) -> CGFloat {
        let row = layout.row(for: key)!
        return row.y + row.height * fraction
    }

    func hit(_ key: SidebarRowKey, _ fraction: CGFloat, dragging: [String] = ["c"]) -> SidebarGroupDwell.Hit? {
        SidebarGroupDwell.hit(y: y(key, fraction), rows: layout.rows, hidden: Set(dragging.map { .workspace(id($0)) }),
                              dragged: dragging.map(id), sections: fixture())
    }

    @Test func aLooseRowMakesANewGroupAGroupedRowOrHeaderJoinsIt() {
        #expect(hit(.workspace(id("a")), 0.5)?.target == .ontoWorkspace(id("a")))
        #expect(hit(.group(g1), 0.5)?.target == .intoGroup(g1))
        #expect(hit(.workspace(id("g2")), 0.5)?.target == .intoGroup(g1))
        #expect(hit(.workspace(id("a")), 0.1)?.fraction == 0.1)
    }

    @Test func nothingToGroupWith() {
        // Another machine, a pinned row, a section header, the dragged row's own group.
        #expect(hit(.workspace(id("x")), 0.5) == nil)
        #expect(hit(.workspace(id("p1")), 0.5) == nil)
        #expect(hit(.section(local), 0.5) == nil)
        #expect(hit(.workspace(id("g1")), 0.5, dragging: ["g3"]) == nil)
    }

    @Test func theMiddleGroupsOnlyAfterTheDwell() {
        var dwell = SidebarGroupDwell()
        let onto = DropTarget.ontoWorkspace(id("a"))
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.1), now: 0) == .none)
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.5), now: 1) == .pending(onto))
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.6), now: 1.2) == .pending(onto))
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.6), now: 1 + SidebarGroupDwell.dwell) == .armed(onto))
    }

    @Test func armedHoldsInTheWiderBandThenLets() {
        var dwell = SidebarGroupDwell()
        let onto = DropTarget.ontoWorkspace(id("a"))
        _ = dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.5), now: 0)
        _ = dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.5), now: 1)
        // Past the middle half, still inside the hold band: stays armed.
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.8), now: 1.1) == .armed(onto))
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.9), now: 1.2) == .none)
        // Back in the middle: the dwell starts over.
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.5), now: 1.3) == .pending(onto))
    }

    @Test func pendingDoesNotHoldInTheWiderBand() {
        var dwell = SidebarGroupDwell()
        let onto = DropTarget.ontoWorkspace(id("a"))
        _ = dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.5), now: 0)
        #expect(dwell.update(SidebarGroupDwell.Hit(target: onto, fraction: 0.8), now: 0.1) == .none)
    }

    @Test func anotherRowStartsOver() {
        var dwell = SidebarGroupDwell()
        _ = dwell.update(SidebarGroupDwell.Hit(target: .ontoWorkspace(id("a")), fraction: 0.5), now: 0)
        _ = dwell.update(SidebarGroupDwell.Hit(target: .ontoWorkspace(id("a")), fraction: 0.5), now: 1)
        #expect(dwell.update(SidebarGroupDwell.Hit(target: .intoGroup(g1), fraction: 0.5), now: 1.1) == .pending(.intoGroup(g1)))
        #expect(dwell.update(nil, now: 1.2) == .none)
    }

    @Test func aNewGroupTakesAColorNoGroupUses() {
        #expect(SidebarGroupDwell.newGroupColor(in: fixture()) == .blue)
        #expect(SidebarGroupDwell.newGroupColor(in: []) == .blue)
    }
}
