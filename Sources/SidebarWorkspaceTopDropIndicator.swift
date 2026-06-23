import SwiftUI

struct SidebarWorkspaceTopDropIndicator: View {
    let isVisible: Bool
    let isFirstRow: Bool
    let rowSpacing: CGFloat
    let isBottomEdge: Bool

    init(
        isVisible: Bool,
        isFirstRow: Bool,
        rowSpacing: CGFloat,
        isBottomEdge: Bool = false
    ) {
        self.isVisible = isVisible
        self.isFirstRow = isFirstRow
        self.rowSpacing = rowSpacing
        self.isBottomEdge = isBottomEdge
    }

    var body: some View {
        if isVisible {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.horizontal, 8)
                .offset(y: indicatorOffset)
        }
    }

    private var indicatorOffset: CGFloat {
        isBottomEdge ? rowSpacing / 2 : (isFirstRow ? 0 : -(rowSpacing / 2))
    }
}
