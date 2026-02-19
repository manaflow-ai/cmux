import SwiftUI

struct NotificationsPage: View {
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @FocusState private var focusedNotificationId: UUID?

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
                                tabTitle: sourceLabel(for: notification.tabId, surfaceId: notification.surfaceId),
                                onOpen: {
                                    // SwiftUI action closures are not guaranteed to run on the main actor.
                                    // Ensure window focus + tab selection happens on the main thread.
                                    DispatchQueue.main.async {
                                        _ = AppDelegate.shared?.openNotification(
                                            tabId: notification.tabId,
                                            surfaceId: notification.surfaceId,
                                            notificationId: notification.id
                                        )
                                        selection = .tabs
                                    }
                                },
                                onClear: {
                                    notificationStore.remove(id: notification.id)
                                },
                                focusedNotificationId: $focusedNotificationId
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: setInitialFocus)
        .onChange(of: notificationStore.notifications.first?.id) { _ in
            setInitialFocus()
        }
    }

    private func setInitialFocus() {
        // Only set focus when the notifications page is visible
        // to avoid stealing focus from the terminal when notifications arrive
        guard selection == .notifications else { return }
        guard let firstId = notificationStore.notifications.first?.id else {
            focusedNotificationId = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedNotificationId = firstId
        }
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

    private func sourceLabel(for tabId: UUID, surfaceId: UUID?) -> String? {
        AppDelegate.shared?.notificationSourceLabel(for: tabId, surfaceId: surfaceId)
            ?? AppDelegate.shared?.tabTitle(for: tabId)
            ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }
}

private struct NotificationRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let focusedNotificationId: FocusState<UUID?>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
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
                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
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
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NotificationRow.\(notification.id.uuidString)")
            .focusable()
            .focused(focusedNotificationId, equals: notification.id)
            .modifier(DefaultActionModifier(isActive: focusedNotificationId.wrappedValue == notification.id))

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
    }
}

private struct DefaultActionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
