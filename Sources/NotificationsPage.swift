import Bonsplit
import SwiftUI

struct NotificationsPage: View {
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @FocusState private var focusedNotificationId: UUID?
    @AppStorage(KeyboardShortcutSettings.Action.jumpToUnread.defaultsKey) private var jumpToUnreadShortcutData = Data()
    @AppStorage(UIZoomMetrics.appStorageKey) private var uiZoomScale = UIZoomMetrics.defaultScale

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
                    .padding(UIZoomMetrics.notificationContainerPadding(uiZoomScale))
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
            Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if !notificationStore.notifications.isEmpty {
                jumpToUnreadButton

                Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, UIZoomMetrics.notificationItemHPadding(uiZoomScale))
        .padding(.vertical, UIZoomMetrics.notificationItemVPadding(uiZoomScale))
    }

    private var emptyState: some View {
        VStack(spacing: UIZoomMetrics.notificationEmptySpacing(uiZoomScale)) {
            Image(systemName: "bell.slash")
                .font(.system(size: UIZoomMetrics.notificationEmptyIconSize(uiZoomScale)))
                .foregroundColor(.secondary)
            Text(String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                .font(.system(size: UIZoomMetrics.notificationTitleFontSize(uiZoomScale), weight: .semibold))
            Text(String(localized: "notifications.empty.description", defaultValue: "Desktop notifications will appear here for quick review."))
                .font(.system(size: UIZoomMetrics.notificationBodyFontSize(uiZoomScale)))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var jumpToUnreadButton: some View {
        if let key = jumpToUnreadShortcut.keyEquivalent {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(key, modifiers: jumpToUnreadShortcut.eventModifiers)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        } else {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        }
    }

    private var jumpToUnreadShortcut: StoredShortcut {
        decodeShortcut(
            from: jumpToUnreadShortcutData,
            fallback: KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut
        )
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notifications.contains(where: { !$0.isRead })
    }

    private func decodeShortcut(from data: Data, fallback: StoredShortcut) -> StoredShortcut {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return fallback
        }
        return shortcut
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabTitle(for: tabId) ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }
}

private struct ShortcutAnnotation: View {
    let text: String
    @AppStorage(UIZoomMetrics.appStorageKey) private var uiZoomScale = UIZoomMetrics.defaultScale

    var body: some View {
        Text(text)
            .font(.system(size: UIZoomMetrics.notificationHeaderFontSize(uiZoomScale), weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, UIZoomMetrics.notificationHeaderHPadding(uiZoomScale))
            .padding(.vertical, UIZoomMetrics.notificationHeaderVPadding(uiZoomScale))
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

private struct NotificationRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let focusedNotificationId: FocusState<UUID?>.Binding
    @AppStorage(UIZoomMetrics.appStorageKey) private var uiZoomScale = UIZoomMetrics.defaultScale

    var body: some View {
        HStack(alignment: .top, spacing: UIZoomMetrics.notificationRowSpacing(uiZoomScale)) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: UIZoomMetrics.notificationRowSpacing(uiZoomScale)) {
                    Circle()
                        .fill(notification.isRead ? Color.clear : cmuxAccentColor())
                        .frame(width: UIZoomMetrics.notificationDotSize(uiZoomScale), height: UIZoomMetrics.notificationDotSize(uiZoomScale))
                        .overlay(
                            Circle()
                                .stroke(cmuxAccentColor().opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                        )
                        .padding(.top, UIZoomMetrics.notificationRowTopPadding(uiZoomScale))

                    VStack(alignment: .leading, spacing: UIZoomMetrics.notificationRowVStackSpacing(uiZoomScale)) {
                        HStack {
                            Text(notification.title)
                                .font(.system(size: UIZoomMetrics.notificationTitleFontSize(uiZoomScale), weight: .semibold))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: UIZoomMetrics.notificationCaptionFontSize(uiZoomScale)))
                                .foregroundColor(.secondary)
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.system(size: UIZoomMetrics.notificationBodyFontSize(uiZoomScale)))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        if let tabTitle {
                            Text(tabTitle)
                                .font(.system(size: UIZoomMetrics.notificationCaptionFontSize(uiZoomScale)))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.trailing, UIZoomMetrics.notificationRowTrailingPadding(uiZoomScale))
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
        .padding(UIZoomMetrics.notificationRowPadding(uiZoomScale))
        .background(
            RoundedRectangle(cornerRadius: UIZoomMetrics.notificationRowCornerRadius(uiZoomScale))
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
