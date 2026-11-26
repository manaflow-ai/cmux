import SwiftUI

struct SidebarWorkspaceUnreadBadge: View {
    let unreadCount: Int
    let side: CGFloat
    let font: Font
    let fillColor: Color
    let textColor: Color

    var body: some View {
        ZStack {
            Circle().fill(fillColor)
            Text("\(unreadCount)")
                .font(font)
                .foregroundColor(textColor)
        }
        .frame(width: side, height: side)
    }
}
