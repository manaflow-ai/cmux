import AppKit
@testable import CmuxNextLayout
import Testing

/// `sortSubviews`' comparator reads the stacking ranks through a pointer lent for the one
/// synchronous call (``StackingTable/sort(_:)``), not an object's unretained address.
@MainActor @Suite struct StackingTableTests {
    @Test func subviewsTakeTheirRanksOrderBackToFront() {
        let parent = NSView()
        let views = (0..<4).map { _ in NSView() }
        for view in views { parent.addSubview(view) }
        table(views, ranks: [3, 1, 0, 2]).sort(parent)
        #expect(parent.subviews == [views[2], views[1], views[3], views[0]])
    }

    @Test func aViewWithNoRankSortsAsRankZero() {
        let parent = NSView()
        let ranked = NSView(), unranked = NSView()
        parent.addSubview(ranked)
        parent.addSubview(unranked)
        table([ranked], ranks: [5]).sort(parent)
        #expect(parent.subviews == [unranked, ranked])
    }

    private func table(_ views: [NSView], ranks: [Int]) -> StackingTable {
        var byView: [ObjectIdentifier: Int] = [:]
        for (view, rank) in zip(views, ranks) { byView[ObjectIdentifier(view)] = rank }
        return StackingTable(ranks: byView)
    }
}
