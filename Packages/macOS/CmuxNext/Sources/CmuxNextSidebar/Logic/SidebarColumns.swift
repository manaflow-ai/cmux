import CmuxNextDesign
import CoreGraphics

/// Sidebar grid lines in a row's highlight coordinates. The list owns the outer inset and
/// group nesting; band rows translate these coordinates by their highlight's origin.
nonisolated struct SidebarColumns: Hashable, Sendable {
    var rowWidth: CGFloat
    var comfortable: Bool
    var depth: Int = 0
    var leadingOffset: CGFloat = 0
    var leadingInset: CGFloat = LayoutGrid.sidebarHighlightInset
    var trailingInset: CGFloat = LayoutGrid.sidebarHighlightInset
    /// The least icon column width: a glyph box that grows with a larger text size widens the column.
    var minIconBox: CGFloat = 0
    /// The least distance from the row's end to the first trailing center: the trailing slot's half plus its
    /// clearance from the sidebar resize band (#27954). The grid's line already clears it at the default text
    /// size; a larger control slot moves the column in rather than over the resize edge.
    var minTrailingCenterInset: CGFloat = 0

    var iconBox: CGFloat { max(comfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox, minIconBox) }
    var lead: CGFloat { LayoutGrid.sidebarLead - leadingInset + CGFloat(max(0, depth)) * LayoutGrid.sidebarDepthIndent + leadingOffset }
    var text: CGFloat { lead + iconBox + LayoutGrid.gap }
    /// Only a visible leading icon or pin reserves the icon column. Text-only rows start
    /// at lead, including a group name aligned with its iconless members.
    func text(hasLeadingMark: Bool) -> CGFloat {
        guard hasLeadingMark else {
            // Text-only rows start on lead; an empty icon column is not a gutter.
            return lead
        }
        return text
    }

    var trailingEdge: CGFloat { trailingCenter() + LayoutGrid.iconBox / 2 }

    func mid(height: CGFloat) -> CGFloat { height / 2 }

    func iconFrame(height: CGFloat) -> CGRect {
        CGRect(x: lead, y: mid(height: height) - iconBox / 2, width: iconBox, height: iconBox)
    }

    func disclosureFrame(height: CGFloat) -> CGRect {
        CGRect(x: lead - LayoutGrid.iconBox, y: mid(height: height) - LayoutGrid.iconBox / 2,
               width: LayoutGrid.iconBox, height: LayoutGrid.iconBox)
    }

    func trailingCenter(index: Int = 0) -> CGFloat {
        rowWidth - max(LayoutGrid.sidebarTrailCenter - trailingInset, minTrailingCenterInset)
            - CGFloat(index) * LayoutGrid.sidebarSecondMarkPitch
    }

    func trailingFrame(index: Int = 0, centerY: CGFloat, side: CGFloat) -> CGRect {
        CGRect(x: trailingCenter(index: index) - side / 2, y: centerY - side / 2, width: side, height: side)
    }

    func textEnd(trailingMarks: Int) -> CGFloat {
        guard trailingMarks > 0 else { return trailingEdge }
        return trailingCenter(index: trailingMarks - 1) - LayoutGrid.iconBox / 2 - LayoutGrid.base
    }

    /// The next mark's slot from a right-to-left cursor. Wider labels end on the slot's edge,
    /// growing inward; a small glyph centers in the slot regardless of its drawn size.
    func trailingFrame(before edge: CGFloat, centerY: CGFloat, size: CGSize) -> CGRect {
        let index = max(0, Int(((trailingEdge - edge) / LayoutGrid.sidebarSecondMarkPitch).rounded(.up)))
        let center = trailingCenter(index: index)
        let x = size.width > LayoutGrid.sidebarSecondMarkPitch ? center + LayoutGrid.iconBox / 2 - size.width : center - size.width / 2
        return CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
    }

    /// Reserve whole pitches for a wide badge, so the next mark stays on a column and never overlaps it.
    func trailingEdge(before frame: CGRect) -> CGFloat {
        // Adjacent 20-point hit boxes may touch; their 16-point glyphs still have a gap.
        let gap = frame.width <= LayoutGrid.sidebarSecondMarkPitch
            ? min(LayoutGrid.base, (LayoutGrid.sidebarSecondMarkPitch - frame.width) / 2) : LayoutGrid.base
        let limit = frame.minX - gap
        let slots = max(1, Int(((trailingEdge - limit) / LayoutGrid.sidebarSecondMarkPitch).rounded(.up)))
        return trailingEdge - CGFloat(slots) * LayoutGrid.sidebarSecondMarkPitch
    }

    func textOriginY(centerY: CGFloat, baseline: CGFloat, capHeight: CGFloat) -> CGFloat {
        centerY - baseline + capHeight / 2
    }
}
