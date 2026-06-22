import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Twitter-style bottom tab bar wrapping the connected shell.
///
/// This is the boundary owner for the notifications store: it reads
/// `store.notificationsStore` here (above any `List`) and hands the feed a plain
/// notifications array so no `@Observable` store crosses a `List`/`ForEach`
/// boundary (the snapshot-boundary rule).
///
/// Native `TabView` renders the system tab bar (the Liquid-Glass bar on current
/// iOS). Workspace unread dots and app badges stay on the shared mainline
/// unread-state path rather than being re-derived from this feed.
struct MobileTabContainer: View {
    @Bindable var store: CMUXMobileShellStore
    let signOut: () -> Void
    #if os(iOS)
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    #endif
    @State private var selectedTab: MobileShellTab = .workspaces

    var body: some View {
        TabView(selection: $selectedTab) {
            WorkspaceShellView(
                store: store,
                signOut: signOut
            )
            .tabItem {
                Label(
                    L10n.string("mobile.tab.workspaces", defaultValue: "Workspaces"),
                    systemImage: "square.grid.2x2"
                )
            }
            .tag(MobileShellTab.workspaces)

            if store.supportsNotificationsFeed {
                notificationsTab
                    .tabItem {
                        Label(
                            L10n.string("mobile.tab.notifications", defaultValue: "Notifications"),
                            systemImage: "bell"
                        )
                    }
                    .tag(MobileShellTab.notifications)
            }
        }
        .accessibilityIdentifier("MobileTabBar")
        // Any explicit deep-link navigation (in-app feed tap OR an APNs tap that
        // lands while the user is on Notifications) must bring Workspaces
        // forward so the opened workspace is visible.
        .onChange(of: store.deeplinkWorkspaceNavigationRequest) { _, request in
            guard request != nil else { return }
            selectedTab = .workspaces
        }
        .onChange(of: store.supportsNotificationsFeed) { _, supportsNotificationsFeed in
            if !supportsNotificationsFeed, selectedTab == .notifications {
                selectedTab = .workspaces
            }
        }
        .overlay(alignment: .top) {
            MobileConnectionRecoveryBanner(store: store, signOut: signOut)
        }
    }

    private var notificationsTab: some View {
        NavigationStack {
            NotificationsFeedView(
                notifications: store.notificationsStore.notifications,
                workspaceNamesByID: workspaceNamesByID,
                onOpen: openNotification
            )
        }
    }

    private var workspaceNamesByID: [String: String] {
        Dictionary(uniqueKeysWithValues: store.workspaces.map { ($0.id.rawValue, $0.name) })
    }

    /// Open the workspace a notification belongs to: switch to the Workspaces
    /// tab, select the workspace using the same explicit navigation path as APNs
    /// taps, and mark the workspace read through the Mac-backed workspace
    /// read-state API.
    private func openNotification(_ notification: MobileNotificationPreview) {
        let workspaceID = MobileWorkspacePreview.ID(rawValue: notification.workspaceID)
        #if os(iOS)
        pushCoordinator.handleTap(workspaceId: notification.workspaceID, surfaceId: notification.surfaceID)
        #else
        guard store.workspaces.contains(where: { $0.id == workspaceID }) else { return }
        let surfaceIsReady = notification.surfaceID.map {
            store.workspace(workspaceID, containsSurfaceID: $0)
        } ?? false
        store.navigateToWorkspaceForDeeplink(workspaceID)
        if let surfaceID = notification.surfaceID, surfaceIsReady {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
        }
        #endif
        if store.supportsWorkspaceReadStateActions {
            store.notificationsStore.markReadLocally(forWorkspace: notification.workspaceID)
            Task {
                await store.setWorkspaceUnread(id: workspaceID, false)
                await store.refreshNotifications()
            }
        }
    }
}
