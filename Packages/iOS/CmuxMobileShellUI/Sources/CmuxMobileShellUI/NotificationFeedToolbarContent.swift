#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Toolbar controls shared by the visible notification feed and the compact
/// primary-tab parent. Keeping this preference in one toolbar hierarchy avoids
/// inactive, opacity-hidden feed stacks contributing duplicate items.
struct NotificationFeedToolbarContent: ToolbarContent {
    @Bindable var projection: NotificationFeedProjection
    let requestMarkAllRead: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if projection.sourceUnreadCount > 0 {
                Button(action: requestMarkAllRead) {
                    Label(
                        L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read"),
                        systemImage: "envelope.open"
                    )
                    .labelStyle(.iconOnly)
                }
                .accessibilityLabel(
                    L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read")
                )
                .accessibilityIdentifier("MobileNotificationFeedMarkAllRead")
            }

            NotificationFeedFilterMenu(selection: $projection.filter)
        }
    }
}
#endif
