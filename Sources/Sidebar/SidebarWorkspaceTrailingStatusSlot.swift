import SwiftUI
import AppKit

struct SidebarWorkspaceTrailingStatusSlot: View {
    let showsSpinner: Bool
    let showsBadge: Bool
    let unreadCount: Int
    let side: CGFloat
    let width: CGFloat
    let height: CGFloat
    let badgeFont: Font
    let badgeFillColor: Color
    let badgeTextColor: Color
    let spinnerColor: NSColor
    let spinnerTooltip: String
    let canCloseWorkspace: Bool
    let showsCloseButton: Bool
    let closeButtonTooltip: String
    let closeButtonColor: Color
    let closeButtonFontSize: CGFloat
    let closeAction: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            if showsSpinner {
                SidebarWorkspaceLoadingSpinner(side: side, color: spinnerColor, tooltip: spinnerTooltip)
                    .opacity(canCloseWorkspace && showsCloseButton ? 0 : 1)
                    .transition(.opacity)
            } else if showsBadge {
                SidebarWorkspaceUnreadBadge(
                    unreadCount: unreadCount,
                    side: side,
                    font: badgeFont,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor
                )
                .opacity(canCloseWorkspace && showsCloseButton ? 0 : 1)
                .transition(.opacity)
            }
            if canCloseWorkspace {
                Button(action: closeAction) {
                    CmuxSystemSymbolImage(magnified: "xmark", pointSize: closeButtonFontSize, weight: .medium)
                        .foregroundColor(closeButtonColor)
                        .frame(width: width, height: height, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .safeHelp(closeButtonTooltip)
                .opacity(showsCloseButton ? 1 : 0)
                .allowsHitTesting(showsCloseButton)
                .accessibilityHidden(!showsCloseButton)
            }
        }
        .frame(width: width, height: height, alignment: .trailing)
    }
}
