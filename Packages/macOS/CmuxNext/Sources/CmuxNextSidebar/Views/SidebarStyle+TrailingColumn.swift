import AppKit
import CmuxNextDesign

/// AppKit adapters for the pure grid, measured from the highlight's left edge.
extension SidebarStyle {
    /// The one column source every sidebar row kind reads, in its highlight's coordinates.
    /// `lead` sits `horizontalInset` inside the highlight: the highlight keeps the base list inset
    /// (6 compact, 8 comfortable), and an iconless title starts as far left as the row allows
    /// (Lawrence 2026-10-23), so lead lands 12 / 16 from the sidebar edge. The trailing line is
    /// grid.md's: 24 from the sidebar edge, the row ending `rowEdgeGap` short of it.
    static func columns(rowWidth: CGFloat, depth: Int = 0, leadingOffset: CGFloat = 0) -> SidebarColumns {
        SidebarColumns(rowWidth: rowWidth, comfortable: SidebarDensityTokens.isComfortable,
                       depth: depth, leadingOffset: leadingOffset,
                       leadingInset: LayoutGrid.sidebarLead - horizontalInset,
                       trailingInset: rowEdgeGap, minIconBox: iconBox)
    }

    static var trailingSlotSide: CGFloat { controlSize }

    static func trailingColumnCenterX(rowWidth: CGFloat) -> CGFloat {
        columns(rowWidth: rowWidth).trailingCenter()
    }

    static func trailingColumnStart(rowWidth: CGFloat) -> CGFloat {
        trailingColumnCenterX(rowWidth: rowWidth) - trailingSlotSide / 2
    }

    static func trailingColumnFrame(rowWidth: CGFloat, centerY: CGFloat, side: CGFloat) -> CGRect {
        columns(rowWidth: rowWidth).trailingFrame(centerY: centerY, side: side)
    }

    /// ChromeLabel's alignment rectangle excludes its cell padding; its reported baseline
    /// measures the actual font. Center the capitals, rather than the line box.
    static func textY(_ label: ChromeLabel, centerY: CGFloat) -> CGFloat {
        columns(rowWidth: 0).textOriginY(centerY: centerY, baseline: label.firstBaselineOffsetFromTop,
                                       capHeight: (label.font ?? titleFont).capHeight)
    }

    /// The step between neighbouring trailing slots' centers: a control and the controls' gap. Slot 0 is the column;
    /// slot 1 (a row's disclosure, a header's more) and slot 2 (a hovered row's more, a header's +) step left by
    /// this one pitch, so ⋮ ⌄ ✕ on a hovered row and + ⋮ ⌄ on a group header fall on the same lines (Leo 2026-10-29:
    /// "I SAID THE SHIT WAS MISALIGNED LAST FUCCKING NIGHT"; a hovered row stepped 22 pt then 20 pt).
    static var trailingSlotPitch: CGFloat { LayoutGrid.sidebarSecondMarkPitch }

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
