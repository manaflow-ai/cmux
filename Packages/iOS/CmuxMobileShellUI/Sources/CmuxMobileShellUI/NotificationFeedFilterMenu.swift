#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The feed twin of `WorkspaceListFilterMenu`: read state lives in a toolbar
/// menu instead of a segmented bar above the list, and the icon fills while a
/// narrowing filter is active, mirroring Mail.
struct NotificationFeedFilterMenu: View {
    @Binding var selection: MobileNotificationFeedFilter

    var body: some View {
        Menu {
            Picker(
                L10n.string("mobile.notificationFeed.filter.label", defaultValue: "Notification filter"),
                selection: $selection
            ) {
                Text(L10n.string(
                    "mobile.notificationFeed.filter.allNotifications",
                    defaultValue: "All Notifications"
                ))
                .tag(MobileNotificationFeedFilter.all)
                Text(L10n.string("mobile.notificationFeed.filter.unread", defaultValue: "Unread"))
                    .tag(MobileNotificationFeedFilter.unread)
            }
        } label: {
            Image(systemName: selection == .unread
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.string("mobile.notificationFeed.filter", defaultValue: "Filter"))
        .accessibilityIdentifier("MobileNotificationFeedFilterMenu")
    }
}
#endif
