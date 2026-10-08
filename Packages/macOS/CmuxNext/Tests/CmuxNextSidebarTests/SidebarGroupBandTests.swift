import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// Drag to group on a loose row (spec 1780d02, Leo 2026-10-06): the card's
/// centre in the onto band groups at once, and the band's edges stay sticky
/// once entered, so group and reorder never flicker.
@Suite struct SidebarGroupBandTests {
    let layout = SidebarLayout.make(sections: fixture(), metrics: .standard)

    func hit(_ key: SidebarRowKey, _ fraction: CGFloat, dragging: [String] = ["c"]) -> SidebarGroupBand.Hit? {
        let row = layout.row(for: key)!
        return SidebarGroupBand.hit(y: row.y + row.height * fraction, rows: layout.rows, hidden: Set(dragging.map { .workspace(id($0)) }),
                                    dragged: dragging.map(id), sections: fixture())
    }

    @Test func aLooseRowCanTakeAGroup() throws {
        let a = try #require(hit(.workspace(id("a")), 0.5))
        #expect(a.anchor == id("a"))
        #expect(abs(a.fraction - 0.5) < 0.001)
    }

    @Test func groupRowsPinnedRowsAndOtherMachinesKeepTheLeadingEdgeRule() {
        #expect(hit(.group(g1), 0.5) == nil)
        #expect(hit(.workspace(id("g2")), 0.5) == nil)
        #expect(hit(.workspace(id("x")), 0.5) == nil)
        #expect(hit(.workspace(id("p1")), 0.5) == nil)
        #expect(hit(.section(local), 0.5) == nil)
    }

    @Test func theBandGroupsAtOnceAndItsEdgesAreSticky() {
        var band = SidebarGroupBand()
        let a = id("a")
        #expect(band.update(.init(anchor: a, fraction: 0.1)) == nil)
        #expect(band.update(.init(anchor: a, fraction: 0.5)) == a, "no dwell")
        #expect(band.update(.init(anchor: a, fraction: 0.73)) == a, "sticky past the band's edge")
        #expect(band.update(.init(anchor: a, fraction: 0.8)) == nil)
        #expect(band.update(.init(anchor: a, fraction: 0.73)) == nil, "not sticky until entered again")
    }

    @Test func anotherRowStartsOver() {
        var band = SidebarGroupBand()
        _ = band.update(.init(anchor: id("a"), fraction: 0.5))
        #expect(band.update(.init(anchor: id("b"), fraction: 0.2)) == nil)
        #expect(band.update(nil) == nil)
    }

    /// The first palette color no group uses, never blue or grey (no-blue rule, nxdog70).
    @Test func aNewGroupTakesAColorNoGroupUses() {
        #expect(SidebarGroupBand.newGroupColor(in: fixture()) == .red)
        #expect(SidebarGroupBand.newGroupColor(in: []) == .red)
    }
}
