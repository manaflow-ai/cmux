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
                       minTrailingCenterInset: minTrailingCenterInset,
                       iconBoxOverride: iconColumnOverride,
                       gap: SidebarRowTuning.glyphGap.value, trailingPitch: trailingSlotPitch)
    }

    /// The icon column's width when the tuner or the density sets it, over the grid's rule.
    static var iconColumnOverride: CGFloat? {
        SidebarRowTuning.iconColumn.tunable.override ?? Metrics.densityToken("sidebarIconColumn").map { _ in iconBox }
    }

    static var trailingSlotSide: CGFloat { controlSize }

    /// The room right of the titlebar row's + when it centers on the trailing column (`SidebarView.layout`): the
    /// column's distance from the sidebar's edge less half the button, never under the row's old `space3` inset.
    static var titlebarPlusTrailingInset: CGFloat { max(Metrics.space3, trailingCenterFromEdge - toolbarButtonSize / 2) }

    /// The Default control's 3 pt trailing inset on its 20 pt square, scaled with the control.
    static var trailingControlInset: CGFloat { trailingSlotSide * 3 / 20 }

    /// Every trailing mark and control shares the same center line.
    static var trailingCenterInset: CGFloat { trailingControlInset + trailingSlotSide / 2 }

    /// The trailing column center's distance from the sidebar's edge, past the row's gap; the resize clearance
    /// below still wins if a larger control needs more room.
    static var trailingCenterFromEdge: CGFloat {
        rowEdgeGap + max(trailingCenterInset, minTrailingCenterInset)
    }

    /// Footer Search and row controls must also clear the sidebar resize band.
    static var minTrailingCenterInset: CGFloat {
        trailingColumnInset + max(trailingSlotSide, searchHeight) / 2
    }

    /// The resize band's minimum clearance from the row fill's trailing edge.
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
    /// A browser density (`sidebarLineBoxBaseline`, Default, Comfortable and Spacious) places the baseline as its tab does
    /// (``capCenteredBaseline(_:centerY:scale:)``), so a row's title sits on its tab's baseline.
    static func textY(_ label: ChromeLabel, centerY: CGFloat) -> CGFloat {
        let font = label.font ?? titleFont
        // On the label's own pixel grid (a 1x display snaps to whole points).
        if let baseline = capCenteredBaseline(font, centerY: centerY, scale: label.window?.backingScaleFactor ?? 2) {
            return baseline - label.firstBaselineOffsetFromTop
        }
        return columns(rowWidth: 0).textOriginY(centerY: centerY, baseline: label.firstBaselineOffsetFromTop, capHeight: font.capHeight)
    }
    /// The baseline a tab gives its title, for `font`'s capitals centered on `centerY` (flipped), at a browser density
    /// (`sidebarLineBoxBaseline`); nil at the others, which center the capitals their own way. A tab puts the baseline half
    /// a cap height under its middle, the icon's center, on the pixel grid (`TabCell`), so a row's title sits on its tab's
    /// baseline and centers on its icon at every height (Lucas 2026-11-15: "vertically aligned with the icon always").
    static func capCenteredBaseline(_ font: NSFont, centerY: CGFloat, scale: CGFloat = 2) -> CGFloat? {
        guard Metrics.densityToken("sidebarLineBoxBaseline") != nil else { return nil }
        let s = max(scale, 1)
        return ((centerY + font.capHeight / 2) * s).rounded() / s
    }

    /// The step between neighbouring trailing slots' centers: a control and the controls' gap. Slot 0 is the column;
    /// slot 1 (a hovered row's more, a header's more) and slot 2 (a header's +) step left by
    /// this one pitch, so ⋮ ✕ on a hovered row and + ⋮ ⌄ on a group header fall on the same lines (Leo 2026-10-29:
    /// "I SAID THE SHIT WAS MISALIGNED LAST FUCCKING NIGHT"; a hovered row stepped 22 pt then 20 pt).
    static var trailingSlotPitch: CGFloat { trailingSlotSide + trailingControlGap }

    /// One tenth of a button between adjacent hover squares.
    static var trailingControlGap: CGFloat { trailingSlotSide / 10 }

    /// `value` on the nearest backing pixel: a mark centered on the column stays within half a pixel of it. Flooring
    /// to whole points (the row badge did) put the unread dot up to a point left of the ✕ and the status above it.
    static func pixelSnapped(_ value: CGFloat, scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
}
