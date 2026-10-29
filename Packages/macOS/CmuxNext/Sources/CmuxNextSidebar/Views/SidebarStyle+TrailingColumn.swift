import AppKit
import CmuxNextDesign

/// AppKit adapters for the pure grid, measured from the highlight's left edge.
extension SidebarStyle {
    static func columns(rowWidth: CGFloat, depth: Int = 0, leadingOffset: CGFloat = 0) -> SidebarColumns {
        SidebarColumns(rowWidth: rowWidth, comfortable: SidebarDensityTokens.isComfortable,
                       depth: depth, leadingOffset: leadingOffset)
    }

    static var trailingSlotSide: CGFloat { LayoutGrid.iconBox }

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
}
