#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The two first-class destinations in the mobile app.
enum MobilePrimaryTab: Hashable {
    case workspaces
    case notifications
}

/// Native primary navigation shared by the live shell and deterministic UI
/// fixtures. Keeping the tab construction here guarantees that previews exercise
/// the same labels, symbols, badge behavior, and selection semantics as the app.
struct MobilePrimaryTabScaffold<Workspaces: View, Notifications: View>: View {
    @Binding var selection: MobilePrimaryTab
    let notificationUnreadCount: Int
    let workspaces: Workspaces
    let notifications: Notifications

    init(
        selection: Binding<MobilePrimaryTab>,
        notificationUnreadCount: Int,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications
    ) {
        _selection = selection
        self.notificationUnreadCount = notificationUnreadCount
        self.workspaces = workspaces()
        self.notifications = notifications()
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: MobilePrimaryTab.workspaces) {
                workspaces
            } label: {
                Label(
                    L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"),
                    systemImage: "rectangle.stack"
                )
                .accessibilityIdentifier("MobilePrimaryTabWorkspaces")
            }

            Tab(value: MobilePrimaryTab.notifications) {
                notifications
            } label: {
                Label(
                    L10n.string("mobile.tabs.notifications", defaultValue: "Notifications"),
                    systemImage: "bell"
                )
                .accessibilityIdentifier("MobilePrimaryTabNotifications")
            }
            .badge(notificationUnreadCount)
        }
        .accessibilityIdentifier("MobilePrimaryTabs")
    }
}
#endif
