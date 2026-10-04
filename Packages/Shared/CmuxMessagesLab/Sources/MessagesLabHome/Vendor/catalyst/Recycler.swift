#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The calls `MessagesWindowView` makes on its transcript list. Both
/// `UICollectionView` (default) and `RowRecycler` (`--transcript recycler`)
/// provide them, with the same `ChatLayout`, store, springs and transactions.
protocol TranscriptList: UIScrollView {
    /// performBatchUpdates without a completion handler.
    var visibleCells: [UICollectionViewCell] { get }
    func indexPath(for cell: UICollectionViewCell) -> IndexPath?
    func reloadData()
    func performBatchUpdates(_ updates: (() -> Void)?, completion: ((Bool) -> Void)?)
    func insertItems(at indexPaths: [IndexPath])
    func deleteItems(at indexPaths: [IndexPath])
}

extension UICollectionView: TranscriptList {}
extension TranscriptList {
    func performBatchUpdates(_ updates: (() -> Void)?) { performBatchUpdates(updates, completion: nil) }
}

/// A plain UIScrollView with its own row recycler: a pool of `RowCell`s that
/// is never destroyed. Each layout pass asks `ChatLayout` for the rows in the
/// visible rect; a row keeps its cell while it stays visible (matched by row
/// key, so index shifts from paging do not reconfigure it), leaving rows give
/// their cell back to the pool (hidden, still in the view tree), and new rows
/// take one from the pool. Cells are created only when the pool is empty.
final class RowRecycler: UIScrollView, TranscriptList {
    let layout: ChatLayout
    /// Configure a cell for row index i (the window view's `decorate`).
    var configure: (RowCell, Int) -> Void = { _, _ in }
    /// Row key at index i.
    var key: (Int) -> String = { _ in "" }
    var count: () -> Int = { 0 }

    private var visible: [String: RowCell] = [:]
    private var index: [ObjectIdentifier: Int] = [:]
    private var pool: [RowCell] = []
    private var dirty = true
    /// Cells created (the bench reads `RowCell.created` too).
    private(set) var poolSize = 0

    init(frame: CGRect, layout: ChatLayout) {
        self.layout = layout
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    var visibleCells: [UICollectionViewCell] { Array(visible.values) }

    func indexPath(for cell: UICollectionViewCell) -> IndexPath? {
        index[ObjectIdentifier(cell)].map { IndexPath(item: $0, section: 0) }
    }

    /// All rows may have changed: reconfigure every visible cell on the next pass.
    func reloadData() {
        dirty = true
        setNeedsLayout()
    }

    func performBatchUpdates(_ updates: (() -> Void)?, completion: ((Bool) -> Void)?) {
        updates?()
        setNeedsLayout()
        layoutIfNeeded()
        completion?(true)
    }
    // Rows are matched by key in the next pass; indices need no bookkeeping.
    func insertItems(at indexPaths: [IndexPath]) {}
    func deleteItems(at indexPaths: [IndexPath]) {}

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = layout.collectionViewContentSize
        if contentSize != size { contentSize = size }
        let n = count()
        let attrs = (layout.layoutAttributesForElements(in: bounds) ?? []).filter { $0.indexPath.item < n }
        var next: [String: RowCell] = [:]
        next.reserveCapacity(attrs.count)
        var newIndex: [ObjectIdentifier: Int] = [:]
        var fresh: [(RowCell, Int)] = []
        let reconfigureAll = dirty
        dirty = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for a in attrs {
            let i = a.indexPath.item
            let k = key(i)
            let cell: RowCell
            if let c = visible.removeValue(forKey: k) {
                cell = c
                if reconfigureAll { fresh.append((c, i)) }
            } else {
                cell = take()
                fresh.append((cell, i))
            }
            if cell.frame != a.frame { cell.frame = a.frame }
            cell.layer.zPosition = CGFloat(a.zIndex)
            next[k] = cell
            newIndex[ObjectIdentifier(cell)] = i
        }
        // Rows that left the rect: back to the pool (hidden, not removed).
        for (_, c) in visible {
            c.isHidden = true
            c.prepareForReuse()
            pool.append(c)
        }
        visible = next
        index = newIndex
        CATransaction.commit()
        for (c, i) in fresh { configure(c, i) }
    }

    private func take() -> RowCell {
        let c: RowCell
        if let p = pool.popLast() {
            c = p
        } else {
            c = RowCell(frame: .zero)
            poolSize += 1
            addSubview(c)
        }
        c.isHidden = false
        return c
    }
}
