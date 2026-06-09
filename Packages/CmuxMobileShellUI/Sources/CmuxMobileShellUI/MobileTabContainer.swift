import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The selectable tabs of the iOS shell. Reverse-DNS-free raw values keep the
/// `TabView` selection stable across launches and make adding a tab a one-line
/// change here plus a `.tabItem` in `body`.
enum MobileShellTab: Hashable {
    case workspaces
    case notifications
}

/// Twitter-style bottom tab bar wrapping the connected shell.
///
/// This is the boundary owner for the notifications store: it reads
/// `store.notificationsStore` here (above any `List`) and hands each child a
/// plain value snapshot — the per-workspace unread map to the workspace list and
/// the notifications array to the feed — so no `@Observable` store crosses a
/// `List`/`ForEach` boundary (the snapshot-boundary rule).
///
/// Native `TabView` renders the system tab bar (the Liquid-Glass bar on current
/// iOS), and the Notifications tab carries a `.badge` of the total unread count.
struct MobileTabContainer: View {
    @Bindable var store: CMUXMobileShellStore
    let signOut: () -> Void
    @State private var selectedTab: MobileShellTab = .workspaces

    var body: some View {
        TabView(selection: $selectedTab) {
            WorkspaceShellView(
                store: store,
                signOut: signOut,
                unreadCountsByWorkspace: store.notificationsStore.unreadCountsByWorkspace()
            )
            .tabItem {
                Label(
                    L10n.string("mobile.tab.workspaces", defaultValue: "Workspaces"),
                    systemImage: "square.grid.2x2"
                )
            }
            .tag(MobileShellTab.workspaces)

            notificationsTab
                .tabItem {
                    Label(
                        L10n.string("mobile.tab.notifications", defaultValue: "Notifications"),
                        systemImage: "bell"
                    )
                }
                .badge(store.notificationsStore.unreadCount)
                .tag(MobileShellTab.notifications)
        }
        .accessibilityIdentifier("MobileTabBar")
    }

    private var notificationsTab: some View {
        NavigationStack {
            NotificationsFeedView(
                notifications: store.notificationsStore.notifications,
                onOpen: openNotification
            )
        }
    }

    /// Open the workspace a notification belongs to: switch to the Workspaces
    /// tab, select the workspace (reusing the same selection path the push
    /// deep-link uses), and optimistically mark its notifications read so the
    /// badge clears immediately (propagated to the Mac for reconciliation).
    private func openNotification(_ notification: MobileNotificationPreview) {
        store.markNotificationsRead(forWorkspace: notification.workspaceID)
        // Switch to the Workspaces tab first, then issue an explicit open request
        // so the compact iPhone stack actually pushes the workspace detail (a
        // bare `selectedWorkspaceID` set leaves the compact UI at the root list).
        selectedTab = .workspaces
        store.requestOpenWorkspace(MobileWorkspacePreview.ID(rawValue: notification.workspaceID))
        if let surfaceID = notification.surfaceID {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
        }
    }
}
