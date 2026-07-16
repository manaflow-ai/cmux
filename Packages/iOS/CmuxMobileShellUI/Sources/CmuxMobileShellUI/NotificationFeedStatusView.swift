#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct NotificationFeedAvailabilityBanner: View {
    let status: MobileNotificationFeedStatus

    var body: some View {
        switch status {
        case .unavailable:
            banner(
                title: L10n.string("mobile.notificationFeed.offline.title", defaultValue: "Notifications are offline"),
                body: L10n.string(
                    "mobile.notificationFeed.offline.inlineBody",
                    defaultValue: "Showing the latest alerts synced from your Macs."
                ),
                systemImage: "wifi.slash"
            )
        case .requiresMacUpdate:
            banner(
                title: L10n.string("mobile.notificationFeed.update.title", defaultValue: "Update cmux on your Mac"),
                body: L10n.string(
                    "mobile.notificationFeed.update.inlineBody",
                    defaultValue: "Some paired Macs cannot sync notifications yet."
                ),
                systemImage: "arrow.down.circle"
            )
        case .idle, .loading, .ready:
            EmptyView()
        }
    }

    private func banner(title: String, body: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileNotificationFeedAvailabilityBanner")
    }
}

enum NotificationFeedEmptyState: Equatable {
    case loading
    case empty
    case allRead
    case unavailable
    case requiresMacUpdate

    static func resolve(
        sourceItemCount: Int,
        filter: MobileNotificationFeedFilter,
        status: MobileNotificationFeedStatus
    ) -> NotificationFeedEmptyState {
        if sourceItemCount > 0, filter == .unread {
            return .allRead
        }
        switch status {
        case .idle, .loading:
            return .loading
        case .unavailable:
            return .unavailable
        case .requiresMacUpdate:
            return .requiresMacUpdate
        case .ready:
            return .empty
        }
    }
}

struct NotificationFeedEmptyRow: View {
    let state: NotificationFeedEmptyState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if state == .loading {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel(title)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(iconStyle)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state == .unavailable || state == .requiresMacUpdate {
                Button(
                    L10n.string("mobile.notificationFeed.retry", defaultValue: "Try Again"),
                    action: retry
                )
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("MobileNotificationFeedRetry")
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileNotificationFeedEmptyState")
    }

    private var systemImage: String {
        switch state {
        case .loading: "arrow.triangle.2.circlepath"
        case .empty: "bell.badge"
        case .allRead: "checkmark.circle"
        case .unavailable: "wifi.slash"
        case .requiresMacUpdate: "arrow.down.circle"
        }
    }

    private var iconStyle: Color {
        switch state {
        case .allRead: .green
        case .unavailable, .requiresMacUpdate: .orange
        case .loading, .empty: .accentColor
        }
    }

    private var title: String {
        switch state {
        case .loading:
            L10n.string("mobile.notificationFeed.loading", defaultValue: "Syncing notifications…")
        case .empty:
            L10n.string("mobile.notificationFeed.empty.title", defaultValue: "No notifications yet")
        case .allRead:
            L10n.string("mobile.notificationFeed.allRead.title", defaultValue: "You're all caught up")
        case .unavailable:
            L10n.string("mobile.notificationFeed.offline.title", defaultValue: "Notifications are offline")
        case .requiresMacUpdate:
            L10n.string("mobile.notificationFeed.update.title", defaultValue: "Update cmux on your Mac")
        }
    }

    private var message: String {
        switch state {
        case .loading:
            L10n.string(
                "mobile.notificationFeed.loading.body",
                defaultValue: "Collecting agent alerts from your paired Macs."
            )
        case .empty:
            L10n.string(
                "mobile.notificationFeed.empty.body",
                defaultValue: "Every agent alert from your paired Macs will collect here, even if push alerts are off. Enable push alerts in Settings only when you want an immediate heads-up away from the app."
            )
        case .allRead:
            L10n.string(
                "mobile.notificationFeed.allRead.body",
                defaultValue: "New agent alerts will appear here as they arrive."
            )
        case .unavailable:
            L10n.string(
                "mobile.notificationFeed.offline.body",
                defaultValue: "Reconnect a paired Mac, then pull to refresh."
            )
        case .requiresMacUpdate:
            L10n.string(
                "mobile.notificationFeed.update.body",
                defaultValue: "Install the latest cmux on your paired Macs to sync their notification history."
            )
        }
    }
}
#endif
