import CoreGraphics

/// The paged strip's geometry (`TabsKitToolbarStyle.pagedTabs`): chips of their own widths in one
/// row, a page per chip. Page `i` is the scroll offset that puts chip `i`'s center on the anchor
/// (the screen's center, in the strip's own coordinates). The row is padded at both ends so the
/// first and the last chip can reach the anchor: page 0 is offset 0.
struct StripPaging: Equatable {
    var widths: [CGFloat]
    var gap: CGFloat
    /// Where a selected chip's center sits, from the strip's leading edge.
    var anchor: CGFloat
    /// The strip's visible width.
    var viewport: CGFloat

    var count: Int { widths.count }

    /// Padding before the first chip: its center lands on the anchor at offset 0.
    var leadingPad: CGFloat { max(0, anchor - (widths.first ?? 0) / 2) }
    /// Padding after the last chip: its center lands on the anchor at the end of the row.
    var trailingPad: CGFloat { max(0, viewport - anchor - (widths.last ?? 0) / 2) }

    /// Chip `i`'s center in the row's coordinates.
    func center(_ i: Int) -> CGFloat {
        guard !widths.isEmpty else { return leadingPad }
        let i = min(max(0, i), count - 1)
        var x = leadingPad
        for j in 0..<i { x += widths[j] + gap }
        return x + widths[i] / 2
    }

    /// The scroll offset of page `i`.
    func offset(_ i: Int) -> CGFloat { center(i) - anchor }

    /// The page a scroll offset shows, as a fraction between two pages (below 0 and past the
    /// last page while the strip rubber-bands at an end).
    func position(offset x: CGFloat) -> CGFloat {
        guard count > 1 else { return count == 1 ? (x - offset(0)) / max(1, (widths[0] + gap)) : 0 }
        var previous = offset(0)
        if x <= previous { return (x - previous) / max(1, offset(1) - previous) }
        for i in 1..<count {
            let next = offset(i)
            if x <= next { return CGFloat(i - 1) + (x - previous) / max(1, next - previous) }
            previous = next
        }
        let last = offset(count - 1), before = offset(count - 2)
        return CGFloat(count - 1) + (x - last) / max(1, last - before)
    }

    /// The page a release settles on: one page at most from `start` (the page the drag began
    /// on), toward a fling's direction, else the nearest page to where the scroll would stop.
    func target(start: Int, projected x: CGFloat, velocity: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let low = max(0, start - 1), high = min(count - 1, start + 1)
        let page: Int
        if abs(velocity) > StripPaging.flingVelocity {
            page = start + (velocity > 0 ? 1 : -1)
        } else {
            page = Int(position(offset: x).rounded())
        }
        return min(max(page, low), high)
    }

    /// Points per second past which a release pages toward the fling (UIKit's paging scroll
    /// view turns the page on a short flick).
    static let flingVelocity: CGFloat = 220

    /// A drag stops at the first and the last page: past an end there is no tab to show, so the
    /// row does not move at all (Aziz, 2026-11-24: no swipe where there is no tab).
    static func clamp(_ x: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(x, low), high)
    }

    /// The widest a chip may be on a strip `viewport` wide: narrow enough that a neighbor always
    /// shows `peek` points on either side, so the row reads as paged (more tabs, New Tab).
    static func chipMaxWidth(viewport: CGFloat, gap: CGFloat, cap: CGFloat, peek: CGFloat = 36) -> CGFloat {
        max(60, min(cap, viewport - 2 * (gap + peek)))
    }

    /// The row's full width.
    var contentWidth: CGFloat {
        leadingPad + widths.reduce(0, +) + gap * CGFloat(max(0, count - 1)) + trailingPad
    }
}
