import SwiftUI

struct SidebarWorkspaceUnreadBadge: View {
    let unreadCount: Int
    let side: CGFloat
    let font: Font
    let fillColor: Color
    let textColor: Color

    var body: some View {
        // Single digits keep the classic circle (horizontal padding would push
        // some glyphs into a slightly oval capsule); wider counts grow so
        // 3-digit counts stop clipping. `side` is 16 × fontScale, so side/16
        // recovers the scale for the 5pt end padding (matching the
        // group-header capsule) without a second input. fixedSize keeps
        // greedy siblings (the title's layoutPriority) from compressing the
        // capsule back down to its minimum and truncating the digits.
        Text("\(unreadCount)")
            .font(font)
            .foregroundColor(textColor)
            .padding(.horizontal, unreadCount < 10 ? 0 : side * (5.0 / 16.0))
            .frame(minWidth: side)
            .frame(height: side)
            .background(Capsule().fill(fillColor))
            .fixedSize(horizontal: true, vertical: false)
    }
}
