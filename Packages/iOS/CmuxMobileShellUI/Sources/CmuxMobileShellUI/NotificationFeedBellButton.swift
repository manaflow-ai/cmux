import CmuxMobileSupport
import SwiftUI

/// Workspace-toolbar bell with a capped unread-count badge.
struct NotificationFeedBellButton: View {
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Text(unreadCount > 99
                            ? L10n.string("mobile.notifications.bell.overflow", defaultValue: "99+")
                            : "\(unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 9, y: -8)
                    }
                }
        }
        .accessibilityIdentifier("MobileNotificationBell")
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.notifications.bell.a11y",
                defaultValue: "Notifications, %d unread"
            ),
            unreadCount
        )
    }
}
