import SwiftUI
import AppKit

struct SidebarWorkspaceLeadingStatusSlot: View {
    let showsBadge: Bool
    let showsSpinner: Bool
    let unreadCount: Int
    let side: CGFloat
    let spinnerSide: CGFloat
    let badgeFont: Font
    let badgeFillColor: Color
    let badgeTextColor: Color
    let spinnerColor: NSColor
    let spinnerTooltip: String

    var body: some View {
        ZStack {
            // The spinner replaces the badge entirely (AppKit parity: the
            // hidden badge collapses out of layout); an invisible capsule
            // must not keep sizing the slot by its count.
            if showsBadge && !showsSpinner {
                SidebarWorkspaceUnreadBadge(
                    unreadCount: unreadCount,
                    side: side,
                    font: badgeFont,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor
                )
            }
            if showsSpinner {
                SidebarWorkspaceLoadingSpinner(
                    side: spinnerSide,
                    color: spinnerColor,
                    tooltip: spinnerTooltip
                )
            }
        }
        // Width is a floor, not a fix: the unread badge widens into a capsule
        // for multi-digit counts and must not be clipped back to a circle.
        .frame(minWidth: side)
        .frame(height: side)
        .clipped()
    }
}
