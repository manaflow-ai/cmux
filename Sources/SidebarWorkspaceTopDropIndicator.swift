import CmuxFoundation
import SwiftUI

struct SidebarWorkspaceTopDropIndicator: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let isVisible: Bool
    let isFirstRow: Bool
    let rowSpacing: CGFloat
    let isBottomEdge: Bool
    let leadingInset: CGFloat
    /// Scaled top gap painted above a group header band; `0` keeps today's
    /// placement. When positive the top line centres in the combined gap (the
    /// inter-row spacing plus this in-row gap) instead of sitting on the edge.
    let topInset: CGFloat

    init(
        isVisible: Bool,
        isFirstRow: Bool,
        rowSpacing: CGFloat,
        isBottomEdge: Bool = false,
        leadingInset: CGFloat = 0,
        topInset: CGFloat = 0
    ) {
        self.isVisible = isVisible
        self.isFirstRow = isFirstRow
        self.rowSpacing = rowSpacing
        self.isBottomEdge = isBottomEdge
        self.leadingInset = leadingInset
        self.topInset = topInset
    }

    var body: some View {
        if isVisible {
            Rectangle()
                .fill(cmuxAccent.color)
                .frame(height: SidebarReorderIndicatorView.thickness)
                .padding(.leading, Self.horizontalPadding + max(leadingInset, 0))
                .padding(.trailing, Self.horizontalPadding)
                .offset(y: indicatorOffset)
        }
    }

    private static let horizontalPadding = SidebarReorderIndicatorView.horizontalInset

    private var indicatorOffset: CGFloat {
        if isBottomEdge { return rowSpacing / 2 }
        if topInset > 0 {
            return (topInset - rowSpacing) / 2 - SidebarReorderIndicatorView.thickness / 2
        }
        return isFirstRow ? 0 : -(rowSpacing / 2)
    }
}
