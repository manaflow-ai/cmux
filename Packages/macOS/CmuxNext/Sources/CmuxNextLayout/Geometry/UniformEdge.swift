import CoreGraphics

/// Command on a column edge (resize-modifiers.md): every scrolling column takes one width, and the dragged edge must rest
/// where the pointer puts it, as in every other mode (FRAME OWNER S2B rule D). The columns before the dragged one move
/// its left edge by their growth; the camera keeps the dragged column in place for that only as far as the strip leaves
/// it room (`ColumnScrollState.anchorShift`, then the strip's clamp). So the width is solved for the edge's place on
/// screen (strip space less the camera's rest), with the camera the reducer will give it. One step from now: the widths,
/// the left edge, the content and the camera are the strip's now, as the reducer's anchored sync starts from them.
nonisolated struct UniformEdge: Hashable, Sendable {
    /// The scrolling columns' widths now (points), left to right, and the dragged column's index.
    var widths: [CGFloat]
    var index: Int
    /// The dragged column's left edge now (strip space), the strip's content and viewport widths, the camera's target.
    var left: CGFloat
    var content: CGFloat
    var viewport: CGFloat
    var camera: CGFloat

    init(widths: [CGFloat], index: Int, left: CGFloat, content: CGFloat, viewport: CGFloat, camera: CGFloat) {
        (self.widths, self.index, self.left, self.content, self.viewport, self.camera) = (widths, index, left, content, viewport, camera)
    }

    /// How far the dragged column's left edge moves with every column `width` wide (the anchor's shift).
    func shift(_ width: CGFloat) -> CGFloat { widths.prefix(index).reduce(0) { $0 + width - $1 } }

    /// The camera's rest with every column `width` wide: the anchor's shift as far as the new strip has room, clamped.
    func rest(_ width: CGFloat) -> CGFloat {
        let maxOffset = max(0, content + widths.reduce(0) { $0 + width - $1 } - viewport)
        let shifted = camera + ColumnScrollState.anchorShift(shift(width), target: camera, maxOffset: maxOffset)
        return min(max(shifted, 0), maxOffset)
    }

    /// Where the dragged edge rests on screen (strip space less the camera) with every column `width` wide.
    func edge(_ width: CGFloat) -> CGFloat { left + shift(width) + width - rest(width) }

    /// The width that rests the edge at `place`. The camera is free (it takes the whole shift), at 0, or at the strip's
    /// end; each gives a linear equation, and the first solution whose camera is in that state is the one, within the
    /// pointer's travel of the dragged column's width now: free or at 0 the edge moves at least as far as the width, so a
    /// solution further away is another branch, and taking it would jump every width. Nil when none is: at the strip's
    /// end the content pins the edge (shrinking every column moves it right, or not at all for the last column).
    func width(restingEdgeAt place: CGFloat) -> CGFloat? {
        let k = CGFloat(index), n = CGFloat(widths.count)
        let before = widths.prefix(index).reduce(0, +), all = widths.reduce(0, +)
        var candidates = [place - left + camera, (place - left + before) / (k + 1)]
        if k + 1 != n { candidates.append((place - left + before + content - all - viewport) / (k + 1 - n)) }
        let current = widths[index], reach = abs(place - edge(current)) + 0.01
        return candidates.first { $0 > 0 && abs($0 - current) <= reach && abs(edge($0) - place) < 0.01 }
    }
}
