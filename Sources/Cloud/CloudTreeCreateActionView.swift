import CmuxCloud
import CmuxFoundation
import SwiftUI

/// A hit-testable create row whose action remains visible without hover.
/// Hover comes from the outline's single hover owner (`CloudTreeCellView`),
/// not `onHover`, so it cannot stick after a scroll or reload.
///
/// Like the My Devices action rows, the cell spans the full row width
/// (`CloudTreeNSOutlineView.frameOfCell`), so the hover fill and click target
/// stretch across the row while `contentInset` keeps the glyph on the icon grid.
struct CloudTreeCreateActionView: View {
    let action: CloudTreeCreateAction
    let nodeActions: CloudTreeNodeActions
    let style: CloudTreeStyle
    var isHovered = false
    /// The row's content leading, already scaled for font magnification.
    var contentInset: CGFloat = 0
    /// Where the hover fill starts (`CloudTreeHoverStyle.leading`), already scaled.
    var hoverLeading: CGFloat = CloudTreeHoverStyle.horizontalInset
    /// False when a reload puts the pointer back on this row, so the fill
    /// appears without fading in again.
    var animatesHover = true
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            action.perform(nodeActions)
        } label: {
            CloudTreeCreateActionLabel(action: action, style: style, isHovered: isHovered)
                .padding(.leading, contentInset)
                .frame(maxWidth: .infinity, minHeight: style.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same hover fill as the My Devices action rows.
        // The Cloud sidebar's shared hover shape and fill (`CloudTreeHoverStyle`).
        .background(
            RoundedRectangle(cornerRadius: CloudTreeHoverStyle.cornerRadius, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(CloudTreeHoverStyle.hoverOpacity) : Color.clear)
                .padding(.leading, hoverLeading)
                .padding(.trailing, CloudTreeHoverStyle.horizontalInset)
                .padding(.vertical, CloudTreeHoverStyle.verticalInset)
        )
        .animation(reduceMotion || !animatesHover ? nil : .easeOut(duration: isHovered ? CloudTreeHoverStyle.fadeIn : CloudTreeHoverStyle.fadeOut), value: isHovered)
        .help(action.unavailableHelp ?? action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
