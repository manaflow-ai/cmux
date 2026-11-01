import AppKit
import CmuxNextDesign

/// One trailing accessory column, with neighbouring controls stepping left on the shared slot grid.
/// Its inset reserves the largest trailing hit target at the current appearance density, including
/// footer Search, so every row state stays clear of the sidebar resize band.
extension SidebarStyle {
    /// The column slot's side: a row control's (the chevron's) size.
    static var trailingSlotSide: CGFloat { controlSize }

    /// Inset from the fill edge to the control slot's end: the larger of the row's own inset and the
    /// resize clearance. The slot never ends outside the row's inset (Lawrence: the hover close is the
    /// row's × at the end of the title's line, inside the row's inset), and never nearer the edge than
    /// the resize band's reach plus Search's overhang (#27954: Search can be wider than the slot, and
    /// a trailing click must not grab the resize edge). Comfortable rows' 8 pt inset is the larger;
    /// compact rows' 6 pt inset gives way to the 7 pt clearance.
    static var trailingColumnInset: CGFloat {
        max(horizontalInset, Metrics.space1 + SidebarResizeBand.contentInset +
            max(0, (searchHeight - trailingSlotSide) / 2))
    }

    /// The x every trailing indicator centers on, in a row (or header) of `rowWidth`: the width up to
    /// the row's fill end, then the shared trailing inset. Each caller passes the width of its actual
    /// fill, so no view adds a second horizontal inset.
    static func trailingColumnCenterX(rowWidth: CGFloat) -> CGFloat {
        rowWidth - trailingColumnInset - trailingSlotSide / 2
    }

    /// The column center in the sidebar's coordinate space. List rows end at the shared content
    /// edge (`sidebarWidth - rowTrailingTrim`), while the footer has the sidebar as its parent.
    static func trailingColumnCenterX(sidebarWidth: CGFloat) -> CGFloat {
        sidebarWidth - rowTrailingTrim - horizontalInset - trailingColumnInset - trailingSlotSide / 2
    }

    /// The column slot's leading edge in a row of `rowWidth`: every other trailing control (a
    /// count, the keycap, the hover close and more) ends left of it.
    static func trailingColumnStart(rowWidth: CGFloat) -> CGFloat {
        trailingColumnCenterX(rowWidth: rowWidth) - trailingSlotSide / 2
    }

    /// A `side`-square frame centered on the column x and on `centerY`.
    static func trailingColumnFrame(rowWidth: CGFloat, centerY: CGFloat, side: CGFloat, slot: Int = 0) -> CGRect {
        let x = trailingSlotCenterX(rowWidth: rowWidth, slot: slot) - side / 2
        let end = rowWidth - SidebarResizeBand.contentInset
        return CGRect(x: min(x, end - side), y: centerY - side / 2, width: side, height: side)
    }

    /// Footer coordinates use the same fill edge as the list, without a per-view inset.
    static func trailingColumnFrame(sidebarWidth: CGFloat, centerY: CGFloat, side: CGFloat) -> CGRect {
        trailingColumnFrame(rowWidth: sidebarWidth - rowEdgeGap, centerY: centerY, side: side)
    }

    /// The step between neighbouring trailing slots' centers: a control and the controls' gap. Slot 0 is the column;
    /// slot 1 (a hovered row's more, a header's more) and slot 2 (a header's +) step left by
    /// this one pitch, so ⋮ ✕ on a hovered row and + ⋮ ⌄ on a group header fall on the same lines (Leo 2026-10-29:
    /// "I SAID THE SHIT WAS MISALIGNED LAST FUCCKING NIGHT"; a hovered row stepped 22 pt then 20 pt).
    static var trailingSlotPitch: CGFloat { controlSize + Metrics.space1 }

    /// The center x of trailing slot `slot` (0 is the column) in a row of `rowWidth`.
    static func trailingSlotCenterX(rowWidth: CGFloat, slot: Int) -> CGFloat {
        trailingColumnCenterX(rowWidth: rowWidth) - CGFloat(slot) * trailingSlotPitch
    }

    /// Where the controls left of a column mark end: one slot gap left of the column's slot, so the next control
    /// centers on slot 1. A mark wider than the slot (a badge stack) pushes them left of its own start instead.
    static func trailingAfterColumnMark(markMinX: CGFloat, rowWidth: CGFloat) -> CGFloat {
        let start = trailingColumnStart(rowWidth: rowWidth)
        return markMinX >= start - 0.01 ? start - Metrics.space1 : markMinX - Metrics.space2
    }

    /// `value` on the nearest backing pixel: a mark centered on the column stays within half a pixel of it. Flooring
    /// to whole points (the row badge did) put the unread dot up to a point left of the ✕ and the status above it.
    static func pixelSnapped(_ value: CGFloat, scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
}
