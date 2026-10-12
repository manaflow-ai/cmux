import CoreGraphics

/// Which reuse queue a transcript row's cell goes back to.
///
/// UIKit keeps a cell that scrolls away only while its reuse queue holds
/// fewer than `ceil(1.5 * viewport area / cell area) + 1` views
/// (`-[_UICollectionViewSubviewManager enqueueViewForReuse:]`, iOS 26.5 and
/// 27.0); past that it removes the cell and frees it. With one queue for
/// every message row, short rows crowd it and each tall row that leaves the
/// screen is thrown away, so a later screenful of short rows builds fresh
/// cells mid-scroll.
///
/// Rows instead go to a queue by how many of them fit on screen, `n =
/// floor(viewport / row)`. Rows of a class are at least `viewport / (n_hi +
/// 1)` tall, so at most `n_hi + 2` are on screen at once (one cut at each
/// edge) and a queue never needs more than `n_hi + 1` cells; the class's
/// tallest row, `viewport / n_lo`, lets UIKit queue `ceil(1.5 n_lo) + 1`.
/// Classes start where `n_hi = ceil(1.5 n_lo) - 1` runs out: {0}, {1}, {2},
/// {3, 4}, {5...7}, {8...11}, {12...17}, {18...26}, {27...}. The last holds
/// rows down to a fortieth of the screen, below any message row.
public enum ConversationReuseClass {
    /// The smallest `floor(viewport / row)` of each class.
    static let starts = [0, 1, 2, 3, 5, 8, 12, 18, 27]

    /// The number of reuse queues message rows are spread over.
    public static let count = starts.count

    /// The queue for a row `rowHeight` tall in a viewport `viewportHeight`
    /// tall (cells span the viewport's width).
    public static func index(rowHeight: CGFloat, viewportHeight: CGFloat) -> Int {
        guard rowHeight > 0, viewportHeight > 0 else { return 0 }
        let fits = (viewportHeight / rowHeight).rounded(.down)
        return starts.lastIndex { CGFloat($0) <= fits } ?? 0
    }

    /// How many views UIKit lets a reuse queue hold before it drops the
    /// next cell of `cellHeight` that leaves the screen.
    public static func queueLimit(cellHeight: CGFloat, viewportHeight: CGFloat) -> Int {
        let cellArea = max(1, cellHeight)
        return Int((1.5 * viewportHeight / cellArea).rounded(.up)) + 1
    }
}
