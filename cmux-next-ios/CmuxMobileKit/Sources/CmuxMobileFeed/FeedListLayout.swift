#if os(iOS)
import UIKit

/// The Feed's collection layout: one column of rows whose heights the list
/// already knows (`FeedRowLayout`). Frames are prefix sums, kept until a
/// height or the row count changes, and the visible rows are found by binary
/// search, so a live insert costs one pass of additions instead of a flow
/// layout asking every row for its size again.
final class FeedListLayout: UICollectionViewLayout {
    /// Section 0's one header height, then each event row's height (section 1).
    var headerHeight: CGFloat = 0 { didSet { if headerHeight != oldValue { dirty = true } } }
    private(set) var rowHeights: [CGFloat] = []

    private var dirty = true
    private var tops: [CGFloat] = []
    /// Each row's index by id (the order the heights follow).
    private var index: [String: Int] = [:]

    /// The rows' heights in `order`. `changed`: only these rows' heights may differ (a reconfigure),
    /// so only they are read and the frames below the first of them are summed again; nil: all.
    func setHeights(order: [String], heights: [String: CGFloat], changed: [String]?) {
        // Only when the frames are current for these rows (a full reset waits for prepare()).
        if let changed, !dirty, tops.count == rowHeights.count, order.count == rowHeights.count, !index.isEmpty {
            var first = Int.max
            for id in changed {
                guard let row = index[id], let height = heights[id], rowHeights[row] != height else { continue }
                rowHeights[row] = height
                first = min(first, row)
            }
            if first != Int.max { resum(from: first) }
            return
        }
        index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        rowHeights = order.map { heights[$0] ?? 1 }
        dirty = true
    }

    private func resum(from row: Int) {
        guard !dirty, tops.count == rowHeights.count, row < tops.count else { dirty = true; return }
        var y = tops[row]
        for i in row..<rowHeights.count {
            tops[i] = y
            y += rowHeights[i]
        }
        total = y
    }
    private var width: CGFloat = 0
    private var total: CGFloat = 0

    override func prepare() {
        super.prepare()
        let width = collectionView?.bounds.width ?? 0
        guard dirty || width != self.width else { return }
        self.width = width
        dirty = false
        tops = []
        tops.reserveCapacity(rowHeights.count)
        var y = headerHeight
        for height in rowHeights {
            tops.append(y)
            y += height
        }
        total = y
    }

    override var collectionViewContentSize: CGSize { CGSize(width: width, height: total) }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != width
    }

    private func frame(row: Int) -> CGRect {
        CGRect(x: 0, y: tops[row], width: width, height: rowHeights[row])
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        if indexPath.section == 0 {
            attributes.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        } else {
            guard tops.indices.contains(indexPath.item) else { return nil }
            attributes.frame = frame(row: indexPath.item)
        }
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        if headerHeight > 0, rect.minY < headerHeight, collectionView?.numberOfSections ?? 0 > 0 {
            let header = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
            header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
            result.append(header)
        }
        guard !tops.isEmpty, (collectionView?.numberOfSections ?? 0) > 1 else { return result }
        // The first row whose bottom is below rect.minY.
        var low = 0, high = tops.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + rowHeights[mid] <= rect.minY { low = mid + 1 } else { high = mid }
        }
        var row = low
        while row < tops.count, tops[row] < rect.maxY {
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: row, section: 1))
            attributes.frame = frame(row: row)
            result.append(attributes)
            row += 1
        }
        return result
    }
}
#endif
