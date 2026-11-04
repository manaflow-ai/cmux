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

    /// Switching the Feed to Unread: the list shrinks, `setHeights` runs, then the snapshot is
    /// applied, and UIKit asks for the visible cells before any `prepare()`. TestFlight crash
    /// (cmux INTERNAL 1.2.0, 20261031011229 and 20261026223529): `rowHeights` read past its end
    /// in `layoutAttributesForElements` under `-[UICollectionView _setupCellAnimations]`.
    @Test func aShrinkBeforeTheLayoutPassIsSafe() {
        let layout = FeedListLayout()
        let host = ShrinkHost(layout: layout, rows: 40)
        let all = (0..<40).map { "r\($0)" }
        let heights = Dictionary(uniqueKeysWithValues: all.map { ($0, CGFloat(100)) })
        layout.headerHeight = 50
        layout.setHeights(order: all, heights: heights, changed: nil)
        host.view.layoutIfNeeded()
        // The Unread filter keeps 3 rows; the frames are not summed again yet.
        let unread = Array(all.prefix(3))
        layout.setHeights(order: unread, heights: heights, changed: nil)
        let shown = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 390, height: 2000)) ?? []
        // UIKit still has 40 rows (the batch update has not run), the layout has 3 frames.
        #expect(shown.filter { $0.indexPath.section == 1 }.map(\.indexPath.item) == [0, 1, 2])
        #expect(layout.layoutAttributesForItem(at: IndexPath(item: 5, section: 1)) == nil)
        host.rows = 3
        host.view.reloadData()
        host.view.layoutIfNeeded()
        #expect(host.view.numberOfItems(inSection: 1) == 3)
        #expect(layout.collectionViewContentSize.height == 350)
    }

    /// The same switch through a diffable data source in a window, the path the Feed takes.
    @Test func aDiffableShrinkToUnreadDoesNotTrap() {
        let layout = FeedListLayout()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let view = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "c")
        window.addSubview(view)
        window.isHidden = false
        let source = UICollectionViewDiffableDataSource<Int, String>(collectionView: view) { view, indexPath, _ in
            view.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath)
        }
        let all = (0..<60).map { "r\($0)" }
        let heights = Dictionary(uniqueKeysWithValues: all.map { ($0, CGFloat(80)) })
        func show(_ order: [String]) {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0, 1])
            snapshot.appendItems(["header"], toSection: 0)
            snapshot.appendItems(order, toSection: 1)
            UIView.performWithoutAnimation {
                layout.setHeights(order: order, heights: heights, changed: nil)
                source.apply(snapshot, animatingDifferences: false)
                layout.invalidateLayout()
            }
            view.layoutIfNeeded()
        }
        layout.headerHeight = 40
        show(all)
        view.setContentOffset(CGPoint(x: 0, y: 2400), animated: false)
        view.layoutIfNeeded()
        show(all.enumerated().filter { $0.offset % 7 == 0 }.map(\.element))
        #expect(view.numberOfItems(inSection: 1) == 9)
        show(all)
        #expect(view.numberOfItems(inSection: 1) == 60)
        window.isHidden = true
    }
}

/// A plain two-section data source whose row count the test sets, so UIKit's count can lag
/// the layout's the way it does inside a batch update.
@MainActor
private final class ShrinkHost: NSObject, UICollectionViewDataSource {
    let view: UICollectionView
    var rows: Int

    init(layout: UICollectionViewLayout, rows: Int) {
        self.rows = rows
        view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), collectionViewLayout: layout)
        super.init()
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "c")
        view.dataSource = self
        view.reloadData()
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { 2 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        section == 0 ? 1 : rows
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath)
    }
}
#endif
