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
public enum ConversationReuseClass {
    /// The number of reuse queues message rows are spread over.
    public static let count = 1

    /// The queue for a row `rowHeight` tall in a viewport `viewportHeight`
    /// tall (cells span the viewport's width).
    public static func index(rowHeight: CGFloat, viewportHeight: CGFloat) -> Int {
        0
    }

    /// How many views UIKit lets a reuse queue hold before it drops the
    /// next cell of `cellHeight` that leaves the screen.
    public static func queueLimit(cellHeight: CGFloat, viewportHeight: CGFloat) -> Int {
        let cellArea = max(1, cellHeight)
        return Int((1.5 * viewportHeight / cellArea).rounded(.up)) + 1
    }
}
