import Foundation

/// Pure geometry for drag-to-reorder: which slot a dragged row is over, and
/// how far every other row shifts to open the gap. Kept free of SwiftUI so
/// the math is unit-testable.
enum ReorderMath {
    /// The insertion index for a dragged row.
    ///
    /// Model: the dragged row's center is compared against the other rows'
    /// midpoints at their pre-drag positions; the insertion index is the count
    /// of midpoints above the dragged center. A reorder therefore happens
    /// exactly when the dragged row's center crosses a neighbor's center
    /// (symmetric up/down, no jump at drag start), which matches the feel of
    /// native list reordering.
    ///
    /// - Parameters:
    ///   - heights: visual row heights, in current display order.
    ///   - sourceIndex: the dragged row's index in `heights`.
    ///   - translation: the drag's vertical translation in points.
    ///   - spacing: inter-row spacing.
    static func targetIndex(heights: [CGFloat], sourceIndex: Int, translation: CGFloat, spacing: CGFloat = 0) -> Int {
        guard heights.indices.contains(sourceIndex) else { return max(0, sourceIndex) }
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for height in heights {
            tops.append(y)
            y += height + spacing
        }
        let draggedCenter = tops[sourceIndex] + heights[sourceIndex] / 2 + translation

        var index = 0
        for (i, height) in heights.enumerated() {
            if i == sourceIndex { continue }
            let midpoint = tops[i] + height / 2
            if midpoint < draggedCenter { index += 1 }
        }
        return min(max(index, 0), heights.count - 1)
    }

    /// The vertical shift a non-dragged row takes while a drag is in flight,
    /// opening the gap at `targetIndex` with the dragged row's height.
    static func rowShift(
        index: Int,
        sourceIndex: Int,
        targetIndex: Int,
        draggedHeight: CGFloat,
        spacing: CGFloat = 0
    ) -> CGFloat {
        guard index != sourceIndex else { return 0 }
        let step = draggedHeight + spacing
        if sourceIndex < targetIndex, index > sourceIndex, index <= targetIndex {
            return -step
        }
        if sourceIndex > targetIndex, index >= targetIndex, index < sourceIndex {
            return step
        }
        return 0
    }

    /// `order` with the element at `sourceIndex` moved to `targetIndex`.
    static func reordered<T>(_ order: [T], from sourceIndex: Int, to targetIndex: Int) -> [T] {
        guard order.indices.contains(sourceIndex), order.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return order }
        var out = order
        let moved = out.remove(at: sourceIndex)
        out.insert(moved, at: targetIndex)
        return out
    }
}
