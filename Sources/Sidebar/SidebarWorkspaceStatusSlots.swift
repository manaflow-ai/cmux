import SwiftUI
import AppKit

enum SidebarWorkspaceLoadingTooltip {
    static func text(count: Int) -> String {
        if count == 1 {
            return String(localized: "sidebar.agentActivity.tooltip.one", defaultValue: "Loading (1 active task)")
        }
        return String.localizedStringWithFormat(
            String(localized: "sidebar.agentActivity.tooltip.many", defaultValue: "Loading (%lld active tasks)"),
            Int64(count)
        )
    }
}

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

private struct SidebarWorkspaceUnreadBadge: View {
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

private struct SidebarWorkspaceLoadingSpinner: View {
    let side: CGFloat
    let color: NSColor
    let tooltip: String

    var body: some View {
        SidebarAgentActivityIndicator(spinnerColor: color, side: side)
            .safeHelp(tooltip)
            .accessibilityLabel(Text(tooltip))
    }
}
