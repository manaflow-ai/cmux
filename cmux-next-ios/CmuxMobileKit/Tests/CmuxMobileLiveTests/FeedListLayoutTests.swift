#if os(iOS)
@testable import CmuxMobileFeed
import Testing
import UIKit

/// The Feed's column layout: a changed row re-sums only the frames below it, and gives the
/// same frames as laying everything out again.
@MainActor
@Suite struct FeedListLayoutTests {
    func frames(_ layout: FeedListLayout, count: Int) -> [CGRect] {
        layout.prepare()
        return (0..<count).compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 1))?.frame }
    }

    @Test func aChangedHeightMovesOnlyTheRowsBelowIt() {
        let ids = (0..<5).map { "r\($0)" }
        var heights = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(100)) })
        let layout = FeedListLayout()
        layout.headerHeight = 50
        layout.setHeights(order: ids, heights: heights, changed: nil)
        #expect(frames(layout, count: 5).map(\.minY) == [50, 150, 250, 350, 450])
        heights["r2"] = 160
        layout.setHeights(order: ids, heights: heights, changed: ["r2"])
        let incremental = frames(layout, count: 5)
        #expect(incremental.map(\.minY) == [50, 150, 250, 410, 510])
        #expect(layout.collectionViewContentSize.height == 610)
        let full = FeedListLayout()
        full.headerHeight = 50
        full.setHeights(order: ids, heights: heights, changed: nil)
        #expect(frames(full, count: 5) == incremental)
    }

    /// A reconfigure right after rows were added, before a layout pass, must not trap
    /// (the frames' array was still the old length).
    @Test func aChangeBeforeTheLayoutPassAfterAnInsertIsSafe() {
        let layout = FeedListLayout()
        let few = (0..<3).map { "r\($0)" }
        var heights = Dictionary(uniqueKeysWithValues: (0..<6).map { ("r\($0)", CGFloat(100)) })
        layout.setHeights(order: few, heights: heights, changed: nil)
        _ = frames(layout, count: 3)
        let more = (0..<6).map { "r\($0)" }
        layout.setHeights(order: more, heights: heights, changed: nil)
        heights["r1"] = 140
        layout.setHeights(order: more, heights: heights, changed: ["r1"])
        #expect(frames(layout, count: 6).map(\.minY) == [0, 100, 240, 340, 440, 540])
    }
}
#endif
