import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The Notifications tab: a reverse-chronological feed of notifications that
/// fired across the user's Mac(s), streamed live over the mobile-host channel.
///
/// Per the snapshot-boundary rule, the rows below the `List` receive immutable
/// `MobileNotificationPreview` value snapshots plus an `onOpen` closure — no
/// `@Observable` store crosses the `List`. The owning view (`MobileTabContainer`)
/// reads the store and passes down a plain `[MobileNotificationPreview]`.
struct NotificationsFeedView: View {
    /// Newest-first notifications snapshot. A value array, not a store.
    let notifications: [MobileNotificationPreview]
    /// Current workspace names, keyed by workspace id, from the live workspace list.
    let workspaceNamesByID: [String: String]
    /// Open the workspace a tapped notification belongs to and mark it read.
    let onOpen: (MobileNotificationPreview) -> Void

    var body: some View {
        Group {
            if notifications.isEmpty {
                emptyState
            } else {
                feedList
            }
        }
        .navigationTitle(L10n.string("mobile.notifications.title", defaultValue: "Notifications"))
        .mobileInlineNavigationTitle()
        .accessibilityIdentifier("MobileNotificationsFeed")
    }

    private var feedList: some View {
        List {
            ForEach(notifications) { notification in
                Button {
                    onOpen(notification)
                } label: {
                    NotificationRow(
                        notification: notification,
                        workspaceName: workspaceNamesByID[notification.workspaceID]
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.notifications.empty.title", defaultValue: "No Notifications"),
                systemImage: "bell.slash"
            )
        } description: {
            Text(
                L10n.string(
                    "mobile.notifications.empty.description",
                    defaultValue: "Notifications from your Mac will appear here."
                )
            )
        }
        .accessibilityIdentifier("MobileNotificationsEmpty")
    }
}
