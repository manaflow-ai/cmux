import SwiftUI

struct SidebarWorkspaceBottomDropIndicator: View {
    let isVisible: Bool
    let rowSpacing: CGFloat

    var body: some View {
        if isVisible {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.horizontal, 8)
                .offset(y: rowSpacing / 2)
        }
    }
}
