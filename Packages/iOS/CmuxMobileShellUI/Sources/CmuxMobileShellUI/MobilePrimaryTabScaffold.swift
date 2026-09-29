#if os(iOS)
import CmuxMobileSupport
import SwiftUI

private struct TopContentHitRegion: Shape {
    let bottomInset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: max(0, rect.height - bottomInset)
            )
        )
    }
}

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
                    Tab(value: MobilePrimaryTab.workspaces) {
                        tabBarPlaceholder
                    } label: {
                        workspacesLabel
                    }
                        .accessibilityIdentifier("MobilePrimaryTabWorkspaces")
                    Tab(value: MobilePrimaryTab.notifications) {
                        tabBarPlaceholder
                    } label: {
                        notificationsLabel
                    }
                        .badge(notificationUnreadCount)
                        .accessibilityIdentifier("MobilePrimaryTabNotifications")
                    Tab(value: MobilePrimaryTab.search, role: .search) {
                        tabBarPlaceholder
                    }
                        .accessibilityIdentifier("MobilePrimaryTabSearch")
                }
                .tabViewSearchActivation(.searchTabSelection)
                .tabViewStyle(.tabBarOnly)
                .background(Color.clear)
                .accessibilityIdentifier("MobilePrimaryTabs")
                .animation(nil, value: selection)
                // Each tab owns a NavigationStack. SwiftUI's tab transition
                // otherwise crossfades the stacks before the incoming stack's
                // toolbar items are installed, leaving a blank frame at the
                // top of the screen.
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }
                .overlay(alignment: .top) {
                    // Keep each navigation stack mounted outside the system
                    // tab content transition. iOS 26 crossfades a tab's
                    // hosted NavigationStack before its toolbar items have
                    // been laid out, which produces a blank top frame. This
                    // overlay swaps the already-mounted stacks synchronously;
                    // its bottom inset leaves the native tab bar on top.
                    GeometryReader { geometry in
                        ZStack {
                            workspaces
                                .opacity(selection == .workspaces ? 1 : 0)
                                .allowsHitTesting(selection == .workspaces)
                                .accessibilityHidden(selection != .workspaces)
                            notifications
                                .opacity(selection == .notifications ? 1 : 0)
                                .allowsHitTesting(selection == .notifications)
                                .accessibilityHidden(selection != .notifications)
                            search
                                .environment(\.mobilePrimarySearchDestination, true)
                                .opacity(selection == .search ? 1 : 0)
                                .allowsHitTesting(selection == .search)
                                .accessibilityHidden(selection != .search)
                        }
                        .frame(
                            width: geometry.size.width,
                            height: max(0, geometry.size.height - iOS26TabBarInteractionHeight),
                            alignment: .top
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(TopContentHitRegion(bottomInset: iOS26TabBarInteractionHeight))
                }
                .onChange(of: selection, initial: true) { _, selection in
                    searchCoordinator.synchronizeSelection(selection)
                }

                // The persistent content layer sits above the tab bar's
                // transparent content host, so route the tab bar's hit area
                // back to the same selection binding while leaving its native
                // visuals intact.
                tabBarInteractionOverlay

                if selection == .workspaces, let taskComposerAction {
                    TaskComposerButton(
                        action: taskComposerAction,
                        diameter: iOS26BottomControlDiameter
                    )
                    .padding(.trailing, iOS26BottomControlInset)
                    .padding(.bottom, iOS26TaskComposerBottomPadding)
                    // Compose anchors to the screen, not the keyboard. The
                    // only keyboard that can appear while it is visible
                    // belongs to an overlaying sheet (the composer's
                    // auto-focused prompt), whose inset dragged the button
                    // toward mid-screen and stranded it there whenever the
                    // hide update was missed.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
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
                notifications
                    .tabItem { notificationsLabel }
                    .tag(MobilePrimaryTab.notifications)
                    .badge(notificationUnreadCount)
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

    private var iOS26TabBarInteractionHeight: CGFloat { 90 }

    private var tabBarPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    private var tabBarInteractionOverlay: some View {
        HStack(spacing: 0) {
            tabBarButton(for: .workspaces)
                .frame(width: 110)
            tabBarButton(for: .notifications)
                .frame(width: 110)
            Spacer(minLength: 0)
            tabBarButton(for: .search)
                .frame(width: 90)
        }
        .padding(.horizontal, 45)
        .frame(height: iOS26TabBarInteractionHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func tabBarButton(for tab: MobilePrimaryTab) -> some View {
        Button {
            tabSelection.wrappedValue = tab
        } label: {
            Color.clear
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
    }

    private var tabSelection: Binding<MobilePrimaryTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue.searchScope != nil {
                    if searchCoordinator.isPresented {
                        // The round X returns selection to the previous tab
                        // while search is still presented; it cancels the
                        // query rather than committing it as a filter.
                        searchCoordinator.cancelPresentedSearch()
                    } else if selection == .search {
                        searchCoordinator.deactivateCurrentSearch()
                    }
                }
                // Each primary tab owns a NavigationStack. Letting the
                // selection write inherit SwiftUI's default animation makes
                // UIKit animate the outgoing stack's toolbar away before the
                // incoming stack has installed its own toolbar items. The
                // resulting empty frame is the brief flash seen at the top
                // while switching between Workspaces and Notifications.
                // Keep the tab contents and their navigation state intact,
                // but commit the stack swap as one layout transaction.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selection = newValue
                }
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

        Tab(value: MobilePrimaryTab.notifications) {
            notifications
        } label: {
            notificationsLabel
        }
        .badge(notificationUnreadCount)
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
}

#endif
