#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The mobile app's primary destinations and transient search selection.
enum MobilePrimaryTab: Hashable {
    case workspaces
    case notifications
    case search
}

/// The searchable primary destination that owns the persistent search tab.
///
/// New primary tabs must explicitly choose whether they introduce a search
/// scope or preserve the most recent searchable destination.
private enum MobilePrimarySearchScope {
    case workspaces
    case notifications
}

private extension MobilePrimaryTab {
    var searchScope: MobilePrimarySearchScope? {
        switch self {
        case .workspaces:
            .workspaces
        case .notifications:
            .notifications
        case .search:
            nil
        }
    }
}

/// Native primary navigation shared by the live shell and deterministic UI
/// fixtures. Keeping the tab construction here guarantees that previews exercise
/// the same labels, symbols, badge behavior, and selection semantics as the app.
struct MobilePrimaryTabScaffold<Workspaces: View, Notifications: View>: View {
    @Binding var selection: MobilePrimaryTab
    @Binding var workspaceSearchText: String
    @Binding var notificationSearchText: String
    @State private var searchScope: MobilePrimarySearchScope
    let notificationUnreadCount: Int
    let workspaces: Workspaces
    let notifications: Notifications

    init(
        selection: Binding<MobilePrimaryTab>,
        workspaceSearchText: Binding<String>,
        notificationSearchText: Binding<String>,
        notificationUnreadCount: Int,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications
    ) {
        _selection = selection
        _workspaceSearchText = workspaceSearchText
        _notificationSearchText = notificationSearchText
        _searchScope = State(initialValue: selection.wrappedValue.searchScope ?? .workspaces)
        self.notificationUnreadCount = notificationUnreadCount
        self.workspaces = workspaces()
        self.notifications = notifications()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selection) {
                primaryTabs

                Tab(value: MobilePrimaryTab.search, role: .search) {
                    searchDestination
                }
                .accessibilityIdentifier("MobilePrimaryTabSearch")
            }
            .tabViewSearchActivation(.searchTabSelection)
            .accessibilityIdentifier("MobilePrimaryTabs")
            .onChange(of: selection, initial: true) { _, selection in
                guard let scope = selection.searchScope else { return }
                searchScope = scope
            }
        } else {
            TabView(selection: $selection) {
                primaryTabs
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
        }
    }

    @ViewBuilder
    private var searchDestination: some View {
        switch searchScope {
        case .workspaces:
            workspaces
                .searchable(
                    text: $workspaceSearchText,
                    prompt: L10n.string(
                        "mobile.workspaces.search.placeholder",
                        defaultValue: "Search workspaces"
                    )
                )
        case .notifications:
            notifications
                .searchable(
                    text: $notificationSearchText,
                    prompt: L10n.string(
                        "mobile.notificationFeed.search.placeholder",
                        defaultValue: "Search notifications"
                    )
                )
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
