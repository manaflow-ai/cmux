#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Native primary navigation shared by the live shell and deterministic UI
/// fixtures. Keeping the tab construction here guarantees that previews exercise
/// the same labels, symbols, badge behavior, and selection semantics as the app.
struct MobilePrimaryTabScaffold<
    Workspaces: View,
    Feed: View,
    Notifications: View,
    Cloud: View,
    Search: View
>: View {
    @Binding var selection: MobilePrimaryTab
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let notificationUnreadCount: Int
    let feedNeedsInputCount: Int
    let feedNeedsInputCountProvider: (@MainActor () -> Int)?
    /// False when the Feed replaces the Notifications tab (CMUX Labs).
    let showsNotificationsTab: Bool
    let workspaces: Workspaces
    let feed: Feed
    let notifications: Notifications
    let cloud: Cloud
    let search: Search

    init(
        selection: Binding<MobilePrimaryTab>,
        searchCoordinator: MobilePrimarySearchCoordinator,
        notificationUnreadCount: Int,
        feedNeedsInputCount: Int = 0,
        feedNeedsInputCountProvider: (@MainActor () -> Int)? = nil,
        showsNotificationsTab: Bool = true,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder feed: () -> Feed,
        @ViewBuilder notifications: () -> Notifications,
        @ViewBuilder cloud: () -> Cloud,
        @ViewBuilder search: () -> Search
    ) {
        _selection = selection
        self.searchCoordinator = searchCoordinator
        self.notificationUnreadCount = notificationUnreadCount
        self.feedNeedsInputCount = feedNeedsInputCount
        self.feedNeedsInputCountProvider = feedNeedsInputCountProvider
        self.showsNotificationsTab = showsNotificationsTab
        self.workspaces = workspaces()
        self.feed = feed()
        self.notifications = notifications()
        self.cloud = cloud()
        self.search = search()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            ZStack(alignment: .bottomTrailing) {
                TabView(selection: tabSelection) {
                    primaryTabs

                    if selection == .search || selection.searchScope != nil {
                        Tab(value: MobilePrimaryTab.search, role: .search) {
                            search
                                .environment(\.mobilePrimarySearchDestination, true)
                        }
                        .accessibilityIdentifier("MobilePrimaryTabSearch")
                    }
                }
                .tabViewSearchActivation(.searchTabSelection)
                .accessibilityIdentifier("MobilePrimaryTabs")
                .onChange(of: selection, initial: true) { _, selection in
                    searchCoordinator.synchronizeSelection(selection)
                }

            }
            .ignoresSafeArea(.container, edges: .bottom)
        } else if #available(iOS 18.0, *) {
            TabView(selection: $selection) {
                primaryTabs
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
        } else {
            TabView(selection: $selection) {
                workspaces
                    .tabItem { workspacesLabel }
                    .tag(MobilePrimaryTab.workspaces)
                feed
                    .tabItem { feedLabel }
                    .tag(MobilePrimaryTab.feed)
                    .badge(resolvedFeedNeedsInputCount)
                if showsNotificationsTab {
                    notifications
                        .tabItem { notificationsLabel }
                        .tag(MobilePrimaryTab.notifications)
                        .badge(notificationUnreadCount)
                }
                cloud
                    .tabItem { cloudLabel }
                    .tag(MobilePrimaryTab.cloud)
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
        }
    }

    private var resolvedFeedNeedsInputCount: Int {
        feedNeedsInputCountProvider?() ?? feedNeedsInputCount
    }


    private var tabSelection: Binding<MobilePrimaryTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue != .search {
                    if searchCoordinator.isPresented {
                        // The round X returns selection to the previous tab
                        // while search is still presented; it cancels the
                        // query rather than committing it as a filter.
                        searchCoordinator.cancelPresentedSearch()
                    } else if selection == .search {
                        searchCoordinator.deactivateCurrentSearch()
                    }
                }
                selection = newValue
            }
        )
    }

    @available(iOS 18.0, *)
    @TabContentBuilder<MobilePrimaryTab>
    private var primaryTabs: some TabContent<MobilePrimaryTab> {
        Tab(value: MobilePrimaryTab.workspaces) {
            workspaces
        } label: {
            workspacesLabel
        }

        Tab(value: MobilePrimaryTab.feed) {
            feed
        } label: {
            feedLabel
        }
        .badge(resolvedFeedNeedsInputCount)

        if showsNotificationsTab {
            Tab(value: MobilePrimaryTab.notifications) {
                notifications
            } label: {
                notificationsLabel
            }
            .badge(notificationUnreadCount)
        }
        Tab(value: MobilePrimaryTab.cloud) {
            cloud
        } label: {
            cloudLabel
        }
    }

    private var feedLabel: some View {
        Label(
            L10n.string("mobile.tabs.feed", defaultValue: "Tasks"),
            systemImage: "waveform"
        )
        .accessibilityIdentifier("MobilePrimaryTabTasks")
    }

    private var workspacesLabel: some View {
        Label(
            L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"),
            systemImage: "rectangle.stack"
        )
        .accessibilityIdentifier("MobilePrimaryTabWorkspaces")
    }

    private var notificationsLabel: some View {
        Label(
            L10n.string("mobile.tabs.notifications", defaultValue: "Notifications"),
            systemImage: "bell"
        )
        .accessibilityIdentifier("MobilePrimaryTabNotifications")
    }

    private var cloudLabel: some View {
        Label(
            L10n.string("mobile.tabs.cloud", defaultValue: "Cloud"),
            systemImage: "cloud"
        )
        .accessibilityIdentifier("MobilePrimaryTabCloud")
    }
}

#endif
