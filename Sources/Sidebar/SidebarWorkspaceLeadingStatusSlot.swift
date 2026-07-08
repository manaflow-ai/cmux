import SwiftUI
import AppKit

struct SidebarWorkspaceLeadingStatusSlot: View {
    let showsBadge: Bool
    let showsSpinner: Bool
    let unreadCount: Int
    let side: CGFloat
    let badgeFont: Font
    let badgeFillColor: Color
    let badgeTextColor: Color
    let spinnerColor: NSColor
    let spinnerTooltip: String

    var body: some View {
        ZStack {
            if showsBadge {
                SidebarWorkspaceUnreadBadge(
                    unreadCount: unreadCount,
                    side: side,
                    font: badgeFont,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor
                )
                .opacity(showsSpinner ? 0 : 1)
            }
            if showsSpinner {
                SidebarWorkspaceLoadingSpinner(
                    side: side,
                    color: spinnerColor,
                    tooltip: spinnerTooltip
                )
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}
