#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The mobile app's primary destinations and transient search selection.
enum MobilePrimaryTab: Hashable {
    case workspaces
    case notifications
    case search
}

/// Native primary navigation shared by the live shell and deterministic UI
/// fixtures. Keeping the tab construction here guarantees that previews exercise
/// the same labels, symbols, badge behavior, and selection semantics as the app.
struct MobilePrimaryTabScaffold<Workspaces: View, Notifications: View>: View {
    @Binding var selection: MobilePrimaryTab
    @Binding var searchText: String
    let notificationUnreadCount: Int
    let workspaces: Workspaces
    let notifications: Notifications

    init(
        selection: Binding<MobilePrimaryTab>,
        searchText: Binding<String>,
        notificationUnreadCount: Int,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications
    ) {
        _selection = selection
        _searchText = searchText
        self.notificationUnreadCount = notificationUnreadCount
        self.workspaces = workspaces()
        self.notifications = notifications()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selection) {
                primaryTabs

                Tab(value: MobilePrimaryTab.search, role: .search) {
                    workspaces
                        .searchable(
                            text: $searchText,
                            prompt: L10n.string(
                                "mobile.workspaces.search.placeholder",
                                defaultValue: "Search workspaces"
                            )
                        )
                }
                .hidden(selection == .notifications)
                .accessibilityIdentifier("MobilePrimaryTabSearch")
            }
            .tabViewSearchActivation(.searchTabSelection)
            .accessibilityIdentifier("MobilePrimaryTabs")
        } else {
            TabView(selection: $selection) {
                primaryTabs
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
        }
    }

    @TabContentBuilder<MobilePrimaryTab>
    private var primaryTabs: some TabContent<MobilePrimaryTab> {
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
}
#endif
