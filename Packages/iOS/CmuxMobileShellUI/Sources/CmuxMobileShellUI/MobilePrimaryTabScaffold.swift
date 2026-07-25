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
enum MobilePrimarySearchScope: Equatable {
    case workspaces
    case notifications
}

enum MobilePrimarySearchPhase: Equatable {
    case inactive
    case active(MobilePrimarySearchScope)
    case deactivating(MobilePrimarySearchScope)
}

/// Native primary navigation shared by the live shell and deterministic UI
/// fixtures. Keeping the tab construction here guarantees that previews exercise
/// the same labels, symbols, badge behavior, and selection semantics as the app.
struct MobilePrimaryTabScaffold<
    Workspaces: View,
    Notifications: View,
    WorkspaceSearch: View,
    NotificationSearch: View
>: View {
    @Binding var selection: MobilePrimaryTab
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let notificationUnreadCount: Int
    let workspaces: Workspaces
    let notifications: Notifications
    let workspaceSearch: WorkspaceSearch
    let notificationSearch: NotificationSearch

    init(
        selection: Binding<MobilePrimaryTab>,
        searchCoordinator: MobilePrimarySearchCoordinator,
        notificationUnreadCount: Int,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications,
        @ViewBuilder workspaceSearch: () -> WorkspaceSearch,
        @ViewBuilder notificationSearch: () -> NotificationSearch
    ) {
        _selection = selection
        self.searchCoordinator = searchCoordinator
        self.notificationUnreadCount = notificationUnreadCount
        self.workspaces = workspaces()
        self.notifications = notifications()
        self.workspaceSearch = workspaceSearch()
        self.notificationSearch = notificationSearch()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: tabSelection) {
                primaryTabs

                Tab(value: MobilePrimaryTab.search, role: .search) {
                    searchDestination
                }
                .accessibilityIdentifier("MobilePrimaryTabSearch")
            }
            .searchable(
                text: activeSearchText,
                isPresented: searchPresentation,
                prompt: activeSearchPrompt
            )
            .onSubmit(of: .search) {
                selection = searchCoordinator.commitSubmit()
            }
            .tabViewSearchActivation(.searchTabSelection)
            .accessibilityIdentifier("MobilePrimaryTabs")
            .onChange(of: selection, initial: true) { _, selection in
                searchCoordinator.synchronizeSelection(selection)
            }
        } else {
            TabView(selection: $selection) {
                primaryTabs
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
        }
    }

    private var tabSelection: Binding<MobilePrimaryTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if (selection == .search || searchCoordinator.isPresented),
                   newValue.searchScope != nil {
                    searchCoordinator.deactivateCurrentSearch()
                }
                selection = newValue
            }
        )
    }

    private var searchPresentation: Binding<Bool> {
        Binding(
            get: { searchCoordinator.isPresented },
            set: { presented in
                searchCoordinator.setPresentation(presented)
            }
        )
    }

    @ViewBuilder
    private var searchDestination: some View {
        switch searchCoordinator.scope {
        case .workspaces:
            workspaceSearch
                .modifier(MobilePrimarySearchLifecycleModifier(
                    scope: .workspaces,
                    update: updateSearchLifecycle
                ))
                .environment(\.mobilePrimarySearchDestination, true)
        case .notifications:
            notificationSearch
                .modifier(MobilePrimarySearchLifecycleModifier(
                    scope: .notifications,
                    update: updateSearchLifecycle
                ))
                .environment(\.mobilePrimarySearchDestination, true)
        }
    }

    private var activeSearchText: Binding<String> {
        let scope = searchCoordinator.scope
        let activationGeneration = searchCoordinator.activationGeneration
        return Binding(
            get: { searchCoordinator.nativeSearchText(for: scope) },
            set: { value in
                searchCoordinator.updateNativeSearchText(
                    value,
                    for: scope,
                    activationGeneration: activationGeneration
                )
            }
        )
    }

    private var activeSearchPrompt: Text {
        switch searchCoordinator.scope {
        case .workspaces:
            Text(
                L10n.string(
                    "mobile.workspaces.search.placeholder",
                    defaultValue: "Search workspaces"
                )
            )
        case .notifications:
            Text(
                L10n.string(
                    "mobile.notificationFeed.search.placeholder",
                    defaultValue: "Search notifications"
                )
            )
        }
    }

    private func updateSearchLifecycle(scope: MobilePrimarySearchScope, isSearching: Bool) {
        searchCoordinator.updateLifecycle(scope: scope, isSearching: isSearching)
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

private struct MobilePrimarySearchLifecycleModifier: ViewModifier {
    @Environment(\.isSearching) private var isSearching

    let scope: MobilePrimarySearchScope
    let update: (MobilePrimarySearchScope, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isSearching, initial: true) { _, isSearching in
                update(scope, isSearching)
            }
            .onDisappear {
                update(scope, false)
            }
    }
}
#endif
