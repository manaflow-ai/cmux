import AppKit
import CmuxNextDesign

/// AppKit adapters for the pure grid, measured from the highlight's left edge. The trailing column's
/// line is `trailingCenterInset` inside the fill, and it never comes nearer the fill edge than the largest trailing hit target at
/// the current density (footer Search included) allows, so every row state stays clear of the
/// sidebar resize band.
extension SidebarStyle {
    /// The one column source every sidebar row kind reads, in its highlight's coordinates.
    /// `lead` sits `contentInset` inside the highlight, the padding the row's text has above and below it (Lawrence
    /// 2026-11-09: even on all four sides), and an iconless title starts there (Lawrence 2026-10-23: as far left as the
    /// row allows). The trailing line is `trailingCenterInset` inside the fill, mirroring that inset.
    static func columns(rowWidth: CGFloat, depth: Int = 0, leadingOffset: CGFloat = 0) -> SidebarColumns {
        SidebarColumns(rowWidth: rowWidth, comfortable: SidebarDensityTokens.isComfortable,
                       depth: depth, leadingOffset: leadingOffset,
                       leadingInset: LayoutGrid.sidebarLead - contentInset,
                       trailingCenterInset: trailingCenterInset, minIconBox: iconBox,
                       minTrailingCenterInset: minTrailingCenterInset)
    }

    static var trailingSlotSide: CGFloat { controlSize }

    /// The room right of the titlebar row's + when it centers on the trailing column (`SidebarView.layout`): the
    /// column's distance from the sidebar's edge less half the button, never under the row's old `space3` inset.
    static var titlebarPlusTrailingInset: CGFloat { max(Metrics.space3, trailingCenterFromEdge - toolbarButtonSize / 2) }

    /// How far inside a row's fill the trailing column centers: a status glyph's box (`statusGlyphSize`, the
    /// spinner's and the band's marks' side) ends the row's content inset short of the fill's end, as a row's leading
    /// glyph box starts that inset after its start (`contentInset`; Lawrence 2026-11-09, even on all four sides). Lawrence 2026-11-05: "padding on
    /// left/right of every workspace needs to be even": centering on half the 14 pt mark box (`statusMarkSide`), and the
    /// old floor below, left a compact 10 pt glyph's box 8 pt short of the fill's end against 6 at its start (the running
    /// app's spinner ink 9 vs 6). Leo 2026-11-04 replaced the grid's fixed 24 pt line from the sidebar edge with the
    /// inset rule.
    static var trailingCenterInset: CGFloat { contentInset + statusGlyphSize / 2 }

    /// The trailing column center's distance from the sidebar's edge, past the row's gap; the resize clearance
    /// below still wins if a larger control needs more room.
    static var trailingCenterFromEdge: CGFloat {
        rowEdgeGap + max(trailingCenterInset, minTrailingCenterInset)
    }

    /// The nearest the column's center comes to the fill's end: the largest control on the column (a hover slot, or
    /// footer Search, one footer row tall) still ends `trailingColumnInset` inside the fill, so it never needs the
    /// `trailingColumnFrame` clamp, which would push it off the column. Below `trailingCenterInset` at the shipped
    /// densities, so it moves nothing there.
    static var minTrailingCenterInset: CGFloat {
        trailingColumnInset + max(trailingSlotSide, searchHeight) / 2
    }

    /// Inset from the fill edge to the end of a control on the column that the column never comes nearer than: the
    /// resize clearance (#27954: a trailing click must not grab the resize edge), `trailingClearanceEdge` plus the
    /// band's reach into the sidebar (`SidebarResizeBand.contentInset`) from the sidebar's edge, less the row's gap.
    /// Negative when the gap alone clears the band: a control may then reach into the gap (compact: -2.5, a 24 pt
    /// Search on an 11 pt column ends 1 pt past the fill, 5 pt from the sidebar's edge). It is the exact bound
    /// `trailingColumnFrame` clamps to; until Lawrence 2026-11-05 ("padding on left/right of every workspace needs
    /// to be even") the floor kept the full row inset plus half Search's excess over the slot, which held the
    /// compact column 2.5 pt short of the even inset.
    static var trailingColumnInset: CGFloat {
        trailingClearanceEdge + SidebarResizeBand.contentInset - rowEdgeGap
    }

    /// How far in from the sidebar's edge the trailing clearance above is measured: where a row's fill ended
    /// until 2026-11-02 (1.5 pt, Leo 2026-10-27), kept so the slot's distance from the sidebar's edge is unchanged.
    static let trailingClearanceEdge: CGFloat = 1.5

    /// The x every trailing indicator centers on, in a row (or header) of `rowWidth`: the grid's
    /// trailing line in the row's fill. Each caller passes the width of its actual fill, so no view
    /// adds a second horizontal inset.
    static func trailingColumnCenterX(rowWidth: CGFloat) -> CGFloat {
        columns(rowWidth: rowWidth).trailingCenter()
    }

    /// The column center in the sidebar's coordinate space. List rows end at the shared content
    /// edge (`sidebarWidth - rowTrailingTrim`, less the list inset), while the footer has the sidebar
    /// as its parent.
    static func trailingColumnCenterX(sidebarWidth: CGFloat) -> CGFloat {
        trailingColumnCenterX(rowWidth: sidebarWidth - rowTrailingTrim - horizontalInset)
    }

    /// The column slot's leading edge in a row of `rowWidth`: every other trailing control (a
    /// count, the keycap, the hover close and more) ends left of it.
    static func trailingColumnStart(rowWidth: CGFloat) -> CGFloat {
        trailingColumnCenterX(rowWidth: rowWidth) - trailingSlotSide / 2
    }

    /// A `side`-square frame centered on trailing slot `slot` (0 is the column) and on `centerY`, never
    /// past the resize band's reach. The reach is measured from the sidebar's edge (the fill's end plus
    /// `rowEdgeGap`), from `trailingClearanceEdge` as the column's clearance is, so the row gap moves no slot.
    static func trailingColumnFrame(rowWidth: CGFloat, centerY: CGFloat, side: CGFloat, slot: Int = 0) -> CGRect {
        let frame = columns(rowWidth: rowWidth).trailingFrame(index: slot, centerY: centerY, side: side)
        let end = rowWidth + rowEdgeGap - trailingClearanceEdge - SidebarResizeBand.contentInset
        return CGRect(x: min(frame.minX, end - side), y: frame.minY, width: side, height: side)
    }

    /// Footer coordinates use the same fill edge as the list, without a per-view inset.
    static func trailingColumnFrame(sidebarWidth: CGFloat, centerY: CGFloat, side: CGFloat) -> CGRect {
        trailingColumnFrame(rowWidth: sidebarWidth - rowEdgeGap, centerY: centerY, side: side)
    }

    /// ChromeLabel's alignment rectangle excludes its cell padding; its reported baseline
    /// measures the actual font. Center the capitals, rather than the line box.
    static func textY(_ label: ChromeLabel, centerY: CGFloat) -> CGFloat {
        columns(rowWidth: 0).textOriginY(centerY: centerY, baseline: label.firstBaselineOffsetFromTop,
                                       capHeight: (label.font ?? titleFont).capHeight)
    }

    /// The step between neighbouring trailing slots' centers: a control and the controls' gap. Slot 0 is the column;
    /// slot 1 (a hovered row's more, a header's more) and slot 2 (a header's +) step left by
    /// this one pitch, so ⋮ ✕ on a hovered row and + ⋮ ⌄ on a group header fall on the same lines (Leo 2026-10-29:
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
