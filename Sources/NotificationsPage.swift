import SwiftUI

struct NotificationsPage: View {
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if notificationStore.notifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notificationStore.notifications) { notification in
                            NotificationRow(
                                notification: notification,
                                tabTitle: tabTitle(for: notification.tabId),
                                onOpen: {
                                    tabManager.focusTabFromNotification(notification.tabId, surfaceId: notification.surfaceId)
                                    markReadIfFocused(notification)
                                    selection = .tabs
                                },
                                onClear: {
                                    notificationStore.remove(id: notification.id)
                                }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Notifications")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if !notificationStore.notifications.isEmpty {
                Button("Clear All") {
                    notificationStore.clearAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No notifications yet")
                .font(.headline)
            Text("Desktop notifications will appear here for quick review.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabTitle(for tabId: UUID) -> String? {
        tabManager.tabs.first(where: { $0.id == tabId })?.title
    }

    private func markReadIfFocused(_ notification: TerminalNotification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard tabManager.selectedTabId == notification.tabId else { return }
            if let surfaceId = notification.surfaceId {
                guard tabManager.focusedSurfaceId(for: notification.tabId) == surfaceId else { return }
            }
            notificationStore.markRead(id: notification.id)
        }
    }
}

private struct NotificationRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(notification.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.accentColor.opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                )
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(notification.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(notification.createdAt, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }

                if let tabTitle {
                    Text(tabTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
