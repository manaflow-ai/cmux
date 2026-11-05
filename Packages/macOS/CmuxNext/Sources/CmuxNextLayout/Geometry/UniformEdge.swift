import CoreGraphics

/// Command on a column edge (resize-modifiers.md): every scrolling column takes one width, and the dragged edge must rest
/// where the pointer puts it, as in every other mode (FRAME OWNER S2B rule D). The columns before the dragged one move
/// its left edge by their growth; the camera keeps the dragged column in place for that only as far as the strip leaves
/// it room (`ColumnScrollState.anchorShift`, from the camera's target). So the width is solved for the edge's place on
/// screen (strip space less the camera's value), with the value the reducer's anchored sync will show: the value now plus
/// the shift it applies (a camera mid-spring then carries the edge with every strip column, as in any drag). One step from
/// now: the widths, the left edge, the content and the camera are the strip's now, as that sync starts from them.
nonisolated struct UniformEdge: Hashable, Sendable {
    /// The scrolling columns' widths now (points), left to right, and the dragged column's index.
    var widths: [CGFloat]
    var index: Int
    /// The dragged column's left edge now (strip space), the strip's content and viewport widths, the camera's target and
    /// the value it shows now (the target when the camera is at rest).
    var left: CGFloat
    var content: CGFloat
    var viewport: CGFloat
    var camera: CGFloat
    var shown: CGFloat

    init(widths: [CGFloat], index: Int, left: CGFloat, content: CGFloat, viewport: CGFloat, camera: CGFloat, shown: CGFloat? = nil) {
        (self.widths, self.index, self.left, self.content, self.viewport) = (widths, index, left, content, viewport)
        (self.camera, self.shown) = (camera, shown ?? camera)
    }

    /// How far the dragged column's left edge moves with every column `width` wide (the anchor's shift).
    func shift(_ width: CGFloat) -> CGFloat { widths.prefix(index).reduce(0) { $0 + width - $1 } }

    /// The new strip's room with every column `width` wide.
    func maxOffset(_ width: CGFloat) -> CGFloat { max(0, content + widths.reduce(0) { $0 + width - $1 } - viewport) }

    /// The shift the anchored sync gives the camera (its target and its value alike) with every column `width` wide.
    func cameraShift(_ width: CGFloat) -> CGFloat {
        ColumnScrollState.anchorShift(shift(width), target: camera, maxOffset: maxOffset(width))
    }

    /// The camera's value after the anchored sync with every column `width` wide: the value now plus that shift.
    func presented(_ width: CGFloat) -> CGFloat { shown + cameraShift(width) }

    /// Whether the anchored sync with every column `width` wide adds camera travel: after it the camera still has to go
    /// from the value it shows to its clamped target, and that may only be part of what it had to go before (a camera
    /// mid-spring keeps its own spring; a clamp that stops it is no harm). More, or the other way, moves the strip and the
    /// edge under a still pointer after the frame (a shrink at the strip's end clamps the target back past the value).
    func addsTravel(_ width: CGFloat) -> Bool {
        let target = min(max(camera + cameraShift(width), 0), maxOffset(width))
        let before = camera - shown, after = target - presented(width)
        return after < min(0, before) - 0.01 || after > max(0, before) + 0.01
    }

    /// Where the dragged edge shows (strip space less the camera's value) with every column `width` wide.
    func edge(_ width: CGFloat) -> CGFloat { left + shift(width) + width - presented(width) }

    /// The width that shows the edge at `place`. The camera takes the whole shift, the shift to the strip's start, the
    /// shift to its end, or none (no room); each gives a linear equation, and the first solution whose camera does that
    /// there is the one, within the pointer's travel of the dragged column's width now: in the first, second and last the
    /// edge moves at least as far as the width, so a solution further away is another branch, and taking it would jump
    /// every width. Nil when none is: at the strip's end the content pins the edge (shrinking every column moves it right,
    /// or not at all for the last column), and a width that adds camera travel would slide the edge after the frame. There
    /// the edge holds at its limit: the width it has now, while that adds no travel (nil only if it would).
    func width(restingEdgeAt place: CGFloat) -> CGFloat? {
        let k = CGFloat(index), n = CGFloat(widths.count)
        let before = widths.prefix(index).reduce(0, +), all = widths.reduce(0, +), base = place - left + before + shown
        var candidates = [place - left + shown, (base - camera) / (k + 1), base / (k + 1)]
        if k + 1 != n { candidates.append((base + content - all - viewport - camera) / (k + 1 - n)) }
        let current = widths[index], reach = abs(place - edge(current)) + 0.01
        return candidates.first { $0 > 0 && abs($0 - current) <= reach && abs(edge($0) - place) < 0.01 && !addsTravel($0) }
            ?? (addsTravel(current) ? nil : current)
    }
}
