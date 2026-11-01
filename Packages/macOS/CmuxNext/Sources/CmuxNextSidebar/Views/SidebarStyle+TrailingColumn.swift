import AppKit
import CmuxNextDesign

/// The sidebar's trailing indicator column (Lawrence 2026-10-20: "line everything up with the
/// group header's down chevron"). One slot, `controlSize` wide, ends `horizontalInset` from a row's
/// right edge. The group header's chevron (and its at-rest spinner, a109) and every workspace
/// row's trailing glyph (the unread dot, the working spinner, a warning dot) and every band item's
/// dot or status center on its x, at every density and sidebar width, whatever else the row shows
/// (Lawrence msg 11914: other controls sit left of the column). Header and row layouts read this one place.
extension SidebarStyle {
    /// The column slot's side: a row control's (the chevron's) size.
    static var trailingSlotSide: CGFloat { controlSize }

    /// The x every trailing indicator centers on, in a row (or header) of `rowWidth`: the width up to
    /// the row's fill end (a band item, whose fill is inset by `horizontalInset`, passes its width
    /// less that inset), so every row kind lands on one list x.
    static func trailingColumnCenterX(rowWidth: CGFloat) -> CGFloat {
        rowWidth - horizontalInset - trailingSlotSide / 2
    }

    /// The column slot's leading edge in a row of `rowWidth`: every other trailing control (a
    /// count, the keycap, the hover close and more) ends left of it.
    static func trailingColumnStart(rowWidth: CGFloat) -> CGFloat {
        trailingColumnCenterX(rowWidth: rowWidth) - trailingSlotSide / 2
    }

    /// A `side`-square frame centered on the column x and on `centerY`.
    static func trailingColumnFrame(rowWidth: CGFloat, centerY: CGFloat, side: CGFloat) -> CGRect {
        CGRect(x: trailingColumnCenterX(rowWidth: rowWidth) - side / 2, y: centerY - side / 2, width: side, height: side)
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
