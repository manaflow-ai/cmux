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
    let voiceModeAction: (() -> Void)?
    let workspaces: Workspaces
    let notifications: Notifications
    let search: Search

    init(
        selection: Binding<MobilePrimaryTab>,
        searchCoordinator: MobilePrimarySearchCoordinator,
        notificationUnreadCount: Int,
        taskComposerAction: (() -> Void)? = nil,
        voiceModeAction: (() -> Void)? = nil,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications,
        @ViewBuilder search: () -> Search
    ) {
        _selection = selection
        self.searchCoordinator = searchCoordinator
        self.notificationUnreadCount = notificationUnreadCount
        self.taskComposerAction = taskComposerAction
        self.voiceModeAction = voiceModeAction
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
                        search
                            .environment(\.mobilePrimarySearchDestination, true)
                    }
                    .accessibilityIdentifier("MobilePrimaryTabSearch")
                }
                .tabViewSearchActivation(.searchTabSelection)
                .accessibilityIdentifier("MobilePrimaryTabs")
                .onChange(of: selection, initial: true) { _, selection in
                    searchCoordinator.synchronizeSelection(selection)
                }

                bottomTrailingControls(bottomPadding: iOS26TaskComposerBottomPadding)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        } else if #available(iOS 18.0, *) {
            // Pre-26 OSes get the same floating controls (voice + compose);
            // without them these branches would have no orchestrator
            // entrypoint at all.
            ZStack(alignment: .bottomTrailing) {
                TabView(selection: $selection) {
                    primaryTabs
                }
                .accessibilityIdentifier("MobilePrimaryTabs")
                bottomTrailingControls(bottomPadding: iOS26BottomControlInset)
            }
        } else {
            ZStack(alignment: .bottomTrailing) {
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
                bottomTrailingControls(bottomPadding: iOS26BottomControlInset)
            }
        }
    }

    /// The floating voice + compose stack shared by every OS branch, shown
    /// only on the workspaces tab.
    @ViewBuilder
    private func bottomTrailingControls(bottomPadding: CGFloat) -> some View {
        if selection == .workspaces, taskComposerAction != nil || voiceModeAction != nil {
            VStack(spacing: iOS26BottomControlSpacing) {
                if let voiceModeAction {
                    VoiceModeButton(
                        action: voiceModeAction,
                        diameter: iOS26BottomControlDiameter
                    )
                }
                if let taskComposerAction {
                    TaskComposerButton(
                        action: taskComposerAction,
                        diameter: iOS26BottomControlDiameter
                    )
                }
            }
            .padding(.trailing, iOS26BottomControlInset)
            .padding(.bottom, bottomPadding)
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
