import SwiftUI

struct SidebarWorkspaceTopDropIndicator: View {
    let isVisible: Bool
    let isFirstRow: Bool
    let rowSpacing: CGFloat
    let isBottomEdge: Bool
    let leadingInset: CGFloat

    init(
        isVisible: Bool,
        isFirstRow: Bool,
        rowSpacing: CGFloat,
        isBottomEdge: Bool = false,
        leadingInset: CGFloat = 0
    ) {
        self.isVisible = isVisible
        self.isFirstRow = isFirstRow
        self.rowSpacing = rowSpacing
        self.isBottomEdge = isBottomEdge
        self.leadingInset = leadingInset
    }

    var body: some View {
        if isVisible {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.leading, Self.horizontalPadding + max(leadingInset, 0))
                .padding(.trailing, Self.horizontalPadding)
                .offset(y: indicatorOffset)
        }
    }

    private static let horizontalPadding: CGFloat = 8

    private var indicatorOffset: CGFloat {
        isBottomEdge ? rowSpacing / 2 : (isFirstRow ? 0 : -(rowSpacing / 2))
    }
}
