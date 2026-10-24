@testable import CmuxNextTabs
import Testing

/// Move Tab Left / Right (Opt-Shift-Cmd-[ / ]) beside a tab group. The strip
/// keeps a group's members together, so a one-step move into a group's span
/// was undone by the ordering and nothing visibly moved, with no "at edge"
/// notice (QA spree 2026-10-21). A tab outside a group now steps past the
/// whole group; a member moves among its group's members only.
@MainActor struct MoveTabPastGroupTests {
    /// a, then group G (g1, g2), then x.
    private func model() -> TabStripModel {
        TabStripModel(tabs: [TabItem(id: "a", title: "a"), TabItem(id: "g1", title: "g1", groupID: "G"),
                             TabItem(id: "g2", title: "g2", groupID: "G"), TabItem(id: "x", title: "x")],
                      groups: [TabGroupItem(id: "G")], selectedID: "x")
    }

    /// The display order after moving `id` to `index`, as the daemon's move then the ordering shows it.
    private func order(moving id: TabID, to index: Int, in strip: TabStripModel) -> [TabID] {
        var tabs = strip.orderedTabs
        let tab = tabs.remove(at: tabs.firstIndex { $0.id == id }!)
        tabs.insert(tab, at: index)
        return TabGroupOrdering.normalized(tabs, groups: ["G"]).map(\.id)
    }

    @Test func aTabStepsLeftPastAWholeGroup() throws {
        let strip = model()
        let target = try #require(strip.moveIndex(of: "x", by: -1))
        #expect(order(moving: "x", to: target, in: strip) == ["a", "x", "g1", "g2"])
    }

    @Test func aTabStepsRightPastAWholeGroup() throws {
        let strip = model()
        let target = try #require(strip.moveIndex(of: "a", by: 1))
        #expect(order(moving: "a", to: target, in: strip) == ["g1", "g2", "a", "x"])
    }

    @Test func aMemberMovesInsideItsGroupOnly() throws {
        let strip = model()
        let target = try #require(strip.moveIndex(of: "g1", by: 1))
        #expect(order(moving: "g1", to: target, in: strip) == ["a", "g2", "g1", "x"])
        #expect(strip.moveIndex(of: "g1", by: -1) == nil, "the group's first member is at its edge")
        #expect(strip.moveIndex(of: "g2", by: 1) == nil, "the group's last member is at its edge")
    }

    @Test func theStripsEdgesStillRefuse() {
        #expect(model().moveIndex(of: "a", by: -1) == nil)
        #expect(model().moveIndex(of: "x", by: 1) == nil)
    }
}
