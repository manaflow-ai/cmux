import CmuxCloud
import CmuxFoundation
import CoreGraphics
import Foundation

/// The Cloud sidebar's one hover treatment. Every row, create row and tab
/// uses the same rounded shape and the same neutral fills. A highlight starts
/// just before its row's chevron column, so it follows the tree's indent, and
/// ends a fixed inset from the trailing edge.
struct CloudTreeHoverStyle {
    static let cornerRadius: CGFloat = 6
    /// From the sidebar's trailing edge.
    static let horizontalInset: CGFloat = 6
    /// How far before the chevron column a highlight starts.
    static let leadingOutset: CGFloat = 2
    /// From the row's top and bottom, so stacked highlights keep a hairline gap.
    static let verticalInset: CGFloat = 1
    static let hoverOpacity: CGFloat = 0.05
    static let pressedOpacity: CGFloat = 0.08
    static let selectedOpacity: CGFloat = 0.09
    /// Selection while the tree has keyboard focus.
    static let focusedSelectedOpacity: CGFloat = 0.12
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.08

    /// Where a highlight starts for a row at `level`, scaled for font size:
    /// just before that level's chevron column
    /// (`CloudTreeNSOutlineView.frameOfOutlineCell`).
    @MainActor
    static func leading(level: Int, style: CloudTreeStyle) -> CGFloat {
        GlobalFontMagnification.scaledSize(
            CloudTreeNSOutlineView.leadingMargin + CGFloat(max(0, level)) * style.indentPerLevel - leadingOutset
        )
    }
}
