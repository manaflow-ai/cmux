public import CoreGraphics

/// The strip scrollbar's thumb: a minimap of the visible range over the
/// whole strip (plans/cmux-next/dock-column.md, rules B1 to B4). Pure.
public nonisolated enum StripScrollbarGeometry {
    /// B1. Nil when every column fits (nothing to scroll). Otherwise the
    /// thumb's width is the visible share of the strip, at least
    /// `minimumThumbWidth`, and its position maps 0...maxOffset onto the
    /// track. A rubber-banded offset past an end shortens the thumb at that
    /// end instead of moving it off the track.
    public static func thumb(track: CGRect, offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat,
                             minimumThumbWidth: CGFloat) -> CGRect? {
        let maxOffset = ColumnStripGeometry.maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth)
        guard maxOffset > 0.5, track.width > 0, contentWidth > 0 else { return nil }
        let minimum = min(minimumThumbWidth, track.width)
        let width = max(minimum, track.width * viewportWidth / contentWidth)
        let travel = track.width - width
        let clamped = min(max(offset, 0), maxOffset)
        var rect = CGRect(x: track.minX + travel * clamped / maxOffset, y: track.minY, width: width, height: track.height)
        let overshoot = offset < 0 ? -offset : max(0, offset - maxOffset)
        if overshoot > 0 {
            let shrunk = max(minimum, width - overshoot * track.width / contentWidth)
            if offset > maxOffset { rect.origin.x = rect.maxX - shrunk }
            rect.size.width = shrunk
        }
        return rect
    }

    /// B2. The offset that puts the thumb's leading edge at `thumbMinX`
    /// (a thumb drag), clamped to the strip.
    public static func offset(forThumbMinX thumbMinX: CGFloat, thumbWidth: CGFloat, track: CGRect, maxOffset: CGFloat) -> CGFloat {
        let travel = track.width - thumbWidth
        guard travel > 0, maxOffset > 0 else { return 0 }
        let fraction = min(max((thumbMinX - track.minX) / travel, 0), 1)
        return fraction * maxOffset
    }

    /// B3. A click on the track beside the thumb pages one strip viewport
    /// toward the click and rests on the snap offset nearest that page, at
    /// least one snap step from `offset` so a click always moves. Nil for a
    /// click on the thumb.
    public static func pageTarget(clickX: CGFloat, thumb: CGRect, offset: CGFloat, viewportWidth: CGFloat,
                                  snaps: [CGFloat]) -> CGFloat? {
        guard clickX < thumb.minX || clickX > thumb.maxX, let lowest = snaps.first, let highest = snaps.last else { return nil }
        let direction: CGFloat = clickX < thumb.minX ? -1 : 1
        let page = min(max(offset + direction * viewportWidth, lowest), highest)
        var best = snaps.min { abs($0 - page) < abs($1 - page) } ?? page
        if direction > 0, best <= offset + 0.5 { best = snaps.first { $0 > offset + 0.5 } ?? best }
        if direction < 0, best >= offset - 0.5 { best = snaps.last { $0 < offset - 0.5 } ?? best }
        return best
    }
}
