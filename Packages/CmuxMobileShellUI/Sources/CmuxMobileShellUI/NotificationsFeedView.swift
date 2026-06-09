import CmuxMobileRPC
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
                    NotificationRow(notification: notification)
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

/// One notification row: an unread dot, the workspace/title, body, and a
/// relative timestamp. Renders an immutable value snapshot only.
struct NotificationRow: View {
    let notification: MobileNotificationPreview

    /// The workspace name, falling back to a generic label when the Mac did not
    /// report one (closed or untitled workspace), so the row is never blank.
    private var workspaceLabel: String {
        let name = notification.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return L10n.string("mobile.notifications.unknownWorkspace", defaultValue: "Workspace")
        }
        return name
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(notification.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspaceLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(notification.createdAt, format: .relative(presentation: .numeric))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // The title is an activity string ("Claude finished"); show it
                // under the workspace name so the row reads "<workspace> · <what
                // happened>".
                Text(notification.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !notification.subtitle.isEmpty {
                    Text(notification.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileNotificationRow-\(notification.id)")
    }
}
