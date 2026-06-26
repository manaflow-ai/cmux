import CmuxFoundation
import Bonsplit
import SwiftUI

struct NotificationsPage: View {
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @FocusState private var focusedNotificationId: UUID?
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @AppStorage(PhonePushSettings.forwardEnabledKey) private var forwardToPhone = false
    @AppStorage(PhonePushSettings.hideContentKey) private var hidePhoneNotificationContent = false
    @AppStorage(PhonePushSettings.forwardModeKey) private var forwardToPhoneMode = PhoneForwardingMode.defaultMode.rawValue

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            phoneForwardingRow
            Divider()

            if !notificationStore.notificationMenuSnapshot.hasNotifications {
                emptyState
            } else if notificationStore.notifications.isEmpty {
                workspaceUnreadIndicatorState
            } else {
                notificationsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: setInitialFocus)
        .onChange(of: notificationStore.notifications.first?.id) { _ in
            setInitialFocus()
        }
    }

    private var notificationsList: some View {
        // Build one tabId -> title index per render instead of an O(tabs) lookup
        // for every notification row. Constructing the ForEach then costs
        // O(rows + tabs) rather than O(rows × tabs), which matters when many
        // notifications accumulate (issue #5794).
        let tabTitles = AppDelegate.shared?.tabTitlesByTabId() ?? [:]
        return ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(notificationStore.notifications) { notification in
                    NotificationRow(
                        notification: notification,
                        tabTitle: tabTitle(for: notification.tabId, in: tabTitles),
                        isFocused: focusedNotificationId == notification.id,
                        onOpen: {
                            // SwiftUI action closures are not guaranteed to run on the main actor.
                            // Ensure window focus + tab selection happens on the main thread.
                            DispatchQueue.main.async {
                                _ = AppDelegate.shared?.openTerminalNotification(notification)
                                if notification.clickAction == nil {
                                    selection = .tabs
                                }
                            }
                        },
                        onClear: {
                            notificationStore.remove(id: notification.id)
                        },
                        focusedNotificationId: $focusedNotificationId
                    )
                    // Each NotificationRow renders heavily-modified nested stacks.
                    // Equatable + .equatable() lets a NotificationStore publish that
                    // touches one notification skip body re-evaluation for the other
                    // rows, instead of re-laying out the whole LazyVStack on every
                    // publish (issue #5794, same class as #2586 / #5752).
                    .equatable()
                }
            }
            .padding(16)
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
                .cmuxFont(.title2)
                .fontWeight(.semibold)

            Spacer()

            if notificationStore.notificationMenuSnapshot.hasNotifications {
                jumpToUnreadButton

                Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var phoneForwardingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $forwardToPhone) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "notifications.forwardToPhone.title", defaultValue: "Forward notifications to my iPhone"))
                    Text(String(localized: "notifications.forwardToPhone.subtitle", defaultValue: "Send agent notifications to the cmux iPhone app. Off by default; nothing is uploaded unless this is on."))
                        .cmuxFont(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if forwardToPhone {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(
                        String(localized: "notifications.forwardToPhone.mode.label", defaultValue: "When to send"),
                        selection: $forwardToPhoneMode
                    ) {
                        Text(String(localized: "notifications.forwardToPhone.mode.onlyWhenAway", defaultValue: "Only when away from this Mac"))
                            .tag(PhoneForwardingMode.onlyWhenAway.rawValue)
                        Text(String(localized: "notifications.forwardToPhone.mode.always", defaultValue: "Always"))
                            .tag(PhoneForwardingMode.always.rawValue)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .cmuxFont(.caption)
                    if forwardToPhoneMode == PhoneForwardingMode.onlyWhenAway.rawValue {
                        Text(awayModeExplanation)
                            .cmuxFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 20)
                Toggle(isOn: $hidePhoneNotificationContent) {
                    Text(String(localized: "notifications.forwardToPhone.hideContent", defaultValue: "Hide content (send a generic message instead of the terminal text)"))
                        .cmuxFont(.caption)
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var awayModeExplanation: String {
        let format = String(
            localized: "notifications.forwardToPhone.mode.subtitle",
            defaultValue: "Away means the screen is locked or asleep, the screensaver is running, or there has been no keyboard or mouse input for %lld minutes."
        )
        return String(format: format, Int64(MacPresenceMonitor.recentHardwareInputThreshold / 60))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .cmuxFont(size: 32)
                .foregroundColor(.secondary)
            Text(String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                .cmuxFont(.headline)
            Text(String(localized: "notifications.empty.description", defaultValue: "Desktop notifications will appear here for quick review."))
                .cmuxFont(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceUnreadIndicatorState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.badge")
                .cmuxFont(size: 32)
                .foregroundColor(.secondary)
            Text(notificationStore.notificationMenuSnapshot.stateHintTitle)
                .cmuxFont(.headline)
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
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private func tabTitle(for tabId: UUID, in tabTitles: [UUID: String]) -> String? {
        tabTitles[tabId] ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notificationMenuSnapshot.hasUnreadNotifications
    }
}

struct ShortcutAnnotation: View {
    let text: String
    var accessibilityIdentifier: String? = nil

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            badge.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            badge
        }
    }

    private var badge: some View {
        Text(text)
            .cmuxFont(size: 10, weight: .semibold, design: .rounded)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

struct NotificationRow: View, Equatable {
    // Closures and the focus binding are recreated by the parent on every render
    // and excluded from ==. Equality compares only the value snapshot the row
    // actually renders, so `.equatable()` can suppress body re-evaluation for
    // rows whose snapshot is unchanged (snapshot-boundary rule, CLAUDE.md /
    // issue #2586). `isFocused` is passed in (rather than read from the binding
    // inside the row) precisely so it participates in equality — otherwise a
    // focus change would leave the default-action shortcut on a stale row.
    nonisolated static func == (lhs: NotificationRow, rhs: NotificationRow) -> Bool {
        lhs.notification == rhs.notification &&
            lhs.tabTitle == rhs.tabTitle &&
            lhs.isFocused == rhs.isFocused
    }

    let notification: TerminalNotification
    let tabTitle: String?
    let isFocused: Bool
    let onOpen: () -> Void
    let onClear: () -> Void
    let focusedNotificationId: FocusState<UUID?>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(notification.isRead ? Color.clear : cmuxAccentColor())
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(cmuxAccentColor().opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                        )
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(notification.title)
                                .cmuxFont(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                .cmuxFont(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .cmuxFont(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        if let tabTitle {
                            Text(tabTitle)
                                .cmuxFont(.caption)
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
            .modifier(DefaultActionModifier(isActive: isFocused))

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
