@testable import CmuxTabsKit
import CoreGraphics
import Testing

/// The grid keeps only the cards near the screen built (`CardResidencyPlan`).
struct CardResidencyPlanTests {
    private func pro(count: Int) -> OverviewLayout {
        OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: count)
    }

    /// Runs the plan as the grid does: on-screen cards at once, then one per
    /// step until nothing is left to build, releasing far ones.
    private func settle(_ g: OverviewLayout, offset: CGFloat, built: inout Set<Int>) {
        let plan = CardResidencyPlan()
        for _ in 0..<1000 {
            let step = plan.step(layout: g, offset: offset) { built.contains($0) }
            built.subtract(step.release)
            built.formUnion(step.visible)
            guard let next = step.next else { return }
            built.insert(next)
        }
        Issue.record("never settled")
    }

    /// 80 tabs: wherever the grid rests, every card on screen is built and
    /// the built set stays a few screens of cards (O(visible), not O(tabs)).
    @Test func eightyTabsBuildABoundedSet() {
        let g = pro(count: 80)
        var built = Set<Int>()
        var most = 0
        var offset: CGFloat = 0
        while offset <= g.maxOffset {
            settle(g, offset: offset, built: &built)
            most = max(most, built.count)
            for i in 0..<g.count where g.screenFrame(i, offset: offset).intersects(CGRect(origin: .zero, size: g.size)) {
                #expect(built.contains(i), "card \(i) on screen at \(offset) not built")
            }
            offset += 200
        }
        // Screen plus 3 screens each side built, released past 4: about 9 screens of rows.
        let rowsPerScreen = Int((g.size.height / g.pitch).rounded(.up))
        #expect(most <= 2 * rowsPerScreen * 10)
        #expect(most < g.count)
    }

    /// Scrolling back over a card already built does not build it again
    /// (released only past the release band).
    @Test func scrollingBackKeepsBuiltCards() {
        let g = pro(count: 80)
        var built = Set<Int>()
        settle(g, offset: 0, built: &built)
        let first = built
        settle(g, offset: g.size.height * 2, built: &built)
        #expect(first.isSubset(of: built))
        settle(g, offset: g.size.height * 6, built: &built)
        #expect(!built.contains(0))
    }

    /// The nearest unbuilt card goes first; on-screen cards are reported
    /// for building at once.
    @Test func onScreenFirstThenNearest() {
        let g = pro(count: 30)
        let plan = CardResidencyPlan()
        let empty = plan.step(layout: g, offset: 0) { _ in false }
        #expect(empty.visible.contains(0) && empty.visible.contains(1))
        #expect(empty.next == 0)
        let visible = Set(empty.visible)
        let after = plan.step(layout: g, offset: 0) { visible.contains($0) }
        #expect(after.visible.isEmpty)
        let next = try? #require(after.next)
        #expect(next.map { g.card($0).minY > g.size.height - 400 } == true)
    }
}
