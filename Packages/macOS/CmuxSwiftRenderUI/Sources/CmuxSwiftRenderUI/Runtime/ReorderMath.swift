import Foundation

/// Pure geometry for drag-to-reorder: which slot a dragged row is over, and
/// how far every other row shifts to open the gap. Kept free of SwiftUI so
/// the math is unit-testable.
enum ReorderMath {
    /// The insertion index for a dragged row.
    ///
    /// Model: the dragged row's LEADING edge triggers the swap. Moving up,
    /// the swap happens when the row's top edge passes the midpoint of the
    /// row above; moving down, when its bottom edge passes the midpoint of
    /// the row below. Neighbor midpoints are taken at their pre-drag
    /// positions. Keying the edge on the sign of the total translation (not
    /// the instantaneous direction) keeps the mapping monotonic in
    /// translation, so there is no flip-flop at a boundary.
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
        // Leading edge: top edge when moving up, bottom edge when moving down.
        let edge = translation < 0
            ? tops[sourceIndex] + translation
            : tops[sourceIndex] + heights[sourceIndex] + translation

        var index = 0
        for (i, height) in heights.enumerated() {
            if i == sourceIndex { continue }
            let midpoint = tops[i] + height / 2
            if midpoint < edge { index += 1 }
        }
        return min(max(index, 0), heights.count - 1)
    }

    /// ``targetIndex(heights:sourceIndex:translation:spacing:)`` with
    /// hysteresis: moving AWAY from `current` requires the leading edge to be
    /// past the boundary by `hysteresis` points. Forward and backward swaps at
    /// a slot boundary otherwise share one line, and pointer jitter on that
    /// line flip-flops the target, restarting the gap springs every few
    /// milliseconds (visible churn). The dead band splits the line in two.
    static func targetIndex(
        heights: [CGFloat],
        sourceIndex: Int,
        translation: CGFloat,
        current: Int,
        hysteresis: CGFloat = 6,
        spacing: CGFloat = 0
    ) -> Int {
        // Shrinking |translation| by the margin is conservative for moving
        // OUT (away from the source slot); inflating it is conservative for
        // moving BACK. A transition therefore fires only once its side of the
        // split boundary is clearly crossed.
        let sign: CGFloat = translation >= 0 ? 1 : -1
        let out = targetIndex(
            heights: heights, sourceIndex: sourceIndex,
            translation: translation - sign * hysteresis, spacing: spacing
        )
        let back = targetIndex(
            heights: heights, sourceIndex: sourceIndex,
            translation: translation + sign * hysteresis, spacing: spacing
        )
        func distance(_ index: Int) -> Int { abs(index - sourceIndex) }
        if distance(out) > distance(current) { return out }
        if distance(back) < distance(current) { return back }
        return current
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

    /// The dragged row's remaining visual displacement at drop time: how far
    /// its current visual position (old slot top + pointer translation) sits
    /// from its slot top in the committed new order. The drop hands this to a
    /// settle spring so the row eases from under the pointer into its slot
    /// with no frame of discontinuity.
    static func settleResidual(
        heights: [CGFloat],
        sourceIndex: Int,
        targetIndex: Int,
        translation: CGFloat,
        spacing: CGFloat = 0
    ) -> CGFloat {
        guard heights.indices.contains(sourceIndex), heights.indices.contains(targetIndex) else {
            return 0
        }
        let newOrder = reordered(Array(heights.indices), from: sourceIndex, to: targetIndex)
        var oldTop: CGFloat = 0
        for i in 0..<sourceIndex { oldTop += heights[i] + spacing }
        var newTop: CGFloat = 0
        for i in newOrder.prefix(while: { $0 != sourceIndex }) { newTop += heights[i] + spacing }
        let visualY = oldTop + translation
        return visualY - newTop
    }

    /// The leading indent the dragged row will have at `targetIndex`, derived
    /// from its post-drop neighbors, or `nil` when there is no evidence
    /// (empty list edge cases). Rule: adopt the indent of the row that ends up
    /// directly above; if that row is fixed (a group header), adopt the indent
    /// of the first non-fixed row below it (the group's members); at the very
    /// top, adopt the first non-fixed row's indent.
    ///
    /// Drives the Arc-style X preview while dragging into or out of a group:
    /// the dragged row slides horizontally to the nesting level of its
    /// projected slot before the drop commits.
    static func projectedIndent(
        indents: [CGFloat],
        fixed: [Bool],
        sourceIndex: Int,
        targetIndex: Int
    ) -> CGFloat? {
        guard indents.count == fixed.count,
              indents.indices.contains(sourceIndex),
              indents.indices.contains(targetIndex) else { return nil }
        func firstNonFixed(after start: Int) -> Int? {
            var i = start
            while i < indents.count {
                if i != sourceIndex, !fixed[i] { return i }
                i += 1
            }
            return nil
        }
        let above = targetIndex > sourceIndex ? targetIndex : targetIndex - 1
        if above < 0 || (above == sourceIndex && above == 0) {
            return firstNonFixed(after: 0).map { indents[$0] }
        }
        if fixed[above] {
            return firstNonFixed(after: above + 1).map { indents[$0] }
        }
        return indents[above]
    }

    /// The two nesting candidates at a drop slot: the indent implied by the
    /// row that ends up directly above (its container) and by the first row
    /// that ends up below. When they differ the slot is ambiguous (e.g. right
    /// after a group's last member) and the pointer's X position picks one.
    static func boundaryIndents(
        indents: [CGFloat],
        fixed: [Bool],
        sourceIndex: Int,
        targetIndex: Int
    ) -> (above: CGFloat?, below: CGFloat?) {
        let above = projectedIndent(
            indents: indents, fixed: fixed,
            sourceIndex: sourceIndex, targetIndex: targetIndex
        )
        guard indents.count == fixed.count,
              indents.indices.contains(sourceIndex),
              indents.indices.contains(targetIndex) else { return (above, nil) }
        // First row that ends up below the dragged one after the drop
        // (fixed rows count: a header below means the slot borders the next
        // section, whose header indent approximates the outside level).
        var i = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        while i < indents.count {
            if i != sourceIndex { return (above, indents[i]) }
            i += 1
        }
        return (above, nil)
    }

    /// Picks between the two boundary candidates by the pointer's X position
    /// (base indent + horizontal translation), with hysteresis so jitter on
    /// the midpoint cannot flip-flop. Returns "above" or "below".
    static func boundarySide(
        above: CGFloat?,
        below: CGFloat?,
        pointerX: CGFloat,
        current: String,
        hysteresis: CGFloat = 6
    ) -> String {
        guard let above else { return below == nil ? "above" : "below" }
        guard let below, below != above else { return "above" }
        let currentIndent = current == "below" ? below : above
        let otherIndent = current == "below" ? above : below
        if abs(pointerX - otherIndent) + hysteresis < abs(pointerX - currentIndent) {
            return current == "below" ? "above" : "below"
        }
        return current
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
