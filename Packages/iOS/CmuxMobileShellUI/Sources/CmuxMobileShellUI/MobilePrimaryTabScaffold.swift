#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Native primary navigation shared by the live shell and deterministic UI
/// fixtures. Keeping the tab construction here guarantees that previews exercise
/// the same labels, symbols, badge behavior, and selection semantics as the app.
struct MobilePrimaryTabScaffold<
    Workspaces: View,
    Notifications: View,
    Search: View
>: View {
    @Binding var selection: MobilePrimaryTab
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let notificationUnreadCount: Int
    let taskComposerAction: (() -> Void)?
    let workspaces: Workspaces
    let notifications: Notifications
    let search: Search

    init(
        selection: Binding<MobilePrimaryTab>,
        searchCoordinator: MobilePrimarySearchCoordinator,
        notificationUnreadCount: Int,
        taskComposerAction: (() -> Void)? = nil,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications,
        @ViewBuilder search: () -> Search
    ) {
        _selection = selection
        self.searchCoordinator = searchCoordinator
        self.notificationUnreadCount = notificationUnreadCount
        self.taskComposerAction = taskComposerAction
        self.workspaces = workspaces()
        self.notifications = notifications()
        self.search = search()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            ZStack(alignment: .bottomTrailing) {
                TabView(selection: tabSelection) {
                    primaryTabs

                    Tab(value: MobilePrimaryTab.search, role: .search) {
                        // The search FIELD is attached by each scope's content
                        // to its NavigationStack root (see
                        // MobilePrimarySearchFieldModifier); attached out here,
                        // the platform cannot run its push-minimize/pop-restore
                        // lifecycle and a restored field re-hosts in the top
                        // navigation bar.
                        searchDestination
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

    /// One stable search subtree: the platform adopts the search-role tab's
    /// searchable once per TabView, so the caller provides a SINGLE stack
    /// whose root content switches by scope. Scope-switching between two
    /// stacks left the late-mounted searchable unadopted, and its inactive
    /// field hosted inline at the top after a pop.
    private var searchDestination: some View {
        search
            .modifier(MobilePrimarySearchLifecycleModifier(
                scope: searchCoordinator.scope,
                update: updateSearchLifecycle
            ))
            .environment(\.mobilePrimarySearchDestination, true)
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

#endif
