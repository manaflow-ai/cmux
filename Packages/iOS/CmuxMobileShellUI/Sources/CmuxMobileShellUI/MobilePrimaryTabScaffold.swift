#if os(iOS)
import CmuxMobileSupport
import SwiftUI

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
    let taskComposerAction: (() -> Void)?
    let workspaces: Workspaces
    let notifications: Notifications
    let workspaceSearch: WorkspaceSearch
    let notificationSearch: NotificationSearch
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(
        selection: Binding<MobilePrimaryTab>,
        searchCoordinator: MobilePrimarySearchCoordinator,
        notificationUnreadCount: Int,
        taskComposerAction: (() -> Void)? = nil,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications,
        @ViewBuilder workspaceSearch: () -> WorkspaceSearch,
        @ViewBuilder notificationSearch: () -> NotificationSearch
    ) {
        _selection = selection
        self.searchCoordinator = searchCoordinator
        self.notificationUnreadCount = notificationUnreadCount
        self.taskComposerAction = taskComposerAction
        self.workspaces = workspaces()
        self.notifications = notifications()
        self.workspaceSearch = workspaceSearch()
        self.notificationSearch = notificationSearch()
    }

    var body: some View {
        if isIPadLayout {
            TabView(selection: tabSelection) {
                primaryTabs

                Tab(value: MobilePrimaryTab.search, role: .search) {
                    searchDestination
                        .searchable(
                            text: activeSearchText,
                            isPresented: searchPresentation,
                            prompt: activeSearchPrompt
                        )
                        .onSubmit(of: .search) {
                            selection = searchCoordinator.commitSubmit()
                        }
                }
                .accessibilityIdentifier("MobilePrimaryTabSearch")
            }
            // iPad has enough room for the primary controls to live in a
            // bottom rail. The iOS 26 adaptable tab bar otherwise floats over
            // the split view's navigation toolbar.
            .toolbarVisibility(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MobileIPadPrimaryBar(
                    selection: selection,
                    notificationUnreadCount: notificationUnreadCount,
                    taskComposerAction: taskComposerAction,
                    select: selectTab,
                    beginSearch: {
                        let scope = selection.searchScope ?? searchCoordinator.scope
                        searchCoordinator.beginSearch(for: scope)
                        selectTab(.search)
                    }
                )
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
            .onChange(of: selection, initial: true) { _, selection in
                searchCoordinator.synchronizeSelection(selection)
            }
        } else if #available(iOS 26.0, *) {
            ZStack(alignment: .bottomTrailing) {
                TabView(selection: tabSelection) {
                    primaryTabs

                    Tab(value: MobilePrimaryTab.search, role: .search) {
                        // Scoped to the search tab's content: a TabView-level
                        // searchable is inherited by every tab's navigation bar,
                        // which rendered a second, top search field on the
                        // workspaces and notifications tabs.
                        searchDestination
                            .searchable(
                                text: activeSearchText,
                                isPresented: searchPresentation,
                                prompt: activeSearchPrompt
                            )
                            .onSubmit(of: .search) {
                                selection = searchCoordinator.commitSubmit()
                            }
                    }
                    .accessibilityIdentifier("MobilePrimaryTabSearch")
                }
                .tabViewSearchActivation(.searchTabSelection)
                .accessibilityIdentifier("MobilePrimaryTabs")
                .onChange(of: selection, initial: true) { _, selection in
                    searchCoordinator.synchronizeSelection(selection)
                }

                if selection == .workspaces, let taskComposerAction {
                    TaskComposerButton(
                        action: taskComposerAction,
                        diameter: iOS26BottomControlDiameter
                    )
                    .padding(.trailing, iOS26BottomControlInset)
                    .padding(.bottom, iOS26TaskComposerBottomPadding)
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            TabView(selection: $selection) {
                primaryTabs
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
        }
    }

    private var isIPadLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    /// A tab-view bottom accessory always adds a full-width plate, which is
    /// intended for mini-player content. Compose remains a standalone action
    /// aligned with the detached Search control instead.
    private var iOS26BottomControlDiameter: CGFloat { 62 }
    private var iOS26BottomControlInset: CGFloat { 21 }
    private var iOS26BottomControlSpacing: CGFloat { 12 }
    private var iOS26TaskComposerBottomPadding: CGFloat {
        iOS26BottomControlInset + iOS26BottomControlDiameter + iOS26BottomControlSpacing
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

    private func selectTab(_ tab: MobilePrimaryTab) {
        if (selection == .search || searchCoordinator.isPresented),
           tab.searchScope != nil {
            searchCoordinator.deactivateCurrentSearch()
        }
        selection = tab
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

/// Bottom primary navigation for regular iPad layouts. Keeping this outside
/// the system tab bar leaves each navigation stack's top toolbar responsible
/// for its title and actions, while the large iPad canvas gets a useful bottom
/// control rail.
private struct MobileIPadPrimaryBar: View {
    let selection: MobilePrimaryTab
    let notificationUnreadCount: Int
    let taskComposerAction: (() -> Void)?
    let select: (MobilePrimaryTab) -> Void
    let beginSearch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tabButton(
                .workspaces,
                title: L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"),
                systemImage: "rectangle.stack"
            )
            tabButton(
                .notifications,
                title: L10n.string("mobile.tabs.notifications", defaultValue: "Notifications"),
                systemImage: "bell",
                badge: notificationUnreadCount
            )

            Spacer(minLength: 12)

            Button(action: beginSearch) {
                Label(
                    L10n.string("mobile.tabs.search", defaultValue: "Search"),
                    systemImage: "magnifyingglass"
                )
                .labelStyle(.titleAndIcon)
                .frame(minWidth: 88)
            }
            .accessibilityIdentifier("MobilePrimaryTabSearch")
            .buttonStyle(.bordered)

            if selection == .workspaces, let taskComposerAction {
                TaskComposerButton(
                    action: taskComposerAction,
                    diameter: 56
                )
                .accessibilityLabel(
                    L10n.string("mobile.taskComposer.newTask", defaultValue: "New Task")
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityIdentifier("MobilePrimaryTabBar")
    }

    @ViewBuilder
    private func tabButton(
        _ tab: MobilePrimaryTab,
        title: String,
        systemImage: String,
        badge: Int = 0
    ) -> some View {
        Button {
            select(tab)
        } label: {
            ZStack(alignment: .topTrailing) {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 132)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .offset(x: 7, y: -8)
                        .accessibilityLabel("\(badge)")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(selection == tab ? .accentColor : .secondary)
        .accessibilityIdentifier(
            tab == .workspaces
                ? "MobilePrimaryTabWorkspaces"
                : "MobilePrimaryTabNotifications"
        )
    }
}

#endif
