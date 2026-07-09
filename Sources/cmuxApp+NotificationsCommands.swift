import AppKit
import SwiftUI
import CmuxNotifications

extension cmuxApp {
    @CommandsBuilder
    var notificationsCommands: some Commands {
        CommandMenu(String(localized: "menu.notifications.title", defaultValue: "Notifications")) {
            let snapshot = notificationMenuSnapshot

            Button(snapshot.stateHintTitle) {}
                .disabled(true)

            if !snapshot.recentNotifications.isEmpty {
                Divider()

                ForEach(snapshot.recentNotifications) { notification in
                    Button(notificationMenuItemTitle(for: notification)) {
                        openNotificationFromMainMenu(notification)
                    }
                }

                Divider()
            }

            splitCommandButton(title: String(localized: "menu.notifications.show", defaultValue: "Show Notifications"), shortcut: menuShortcut(for: .showNotifications)) {
                showNotificationsPopover()
            }

            splitCommandButton(title: String(localized: "menu.notifications.jumpToUnread", defaultValue: "Jump to Latest Unread"), shortcut: menuShortcut(for: .jumpToUnread)) {
                appDelegate.jumpToLatestUnread()
            }
            .disabled(!snapshot.hasUnreadNotifications)

            splitCommandButton(title: String(localized: "menu.notifications.toggleUnread", defaultValue: "Toggle Unread"), shortcut: menuShortcut(for: .toggleUnread)) {
                appDelegate.toggleFocusedNotificationUnread()
            }
            .disabled(activeTabManager.selectedWorkspace == nil)

            Button(String(localized: "menu.notifications.markAllRead", defaultValue: "Mark All Read")) {
                notificationStore.markAllRead()
            }
            .disabled(!snapshot.hasUnreadNotifications)

            Button(String(localized: "menu.notifications.clearAll", defaultValue: "Clear All")) {
                notificationStore.clearAll()
            }
            .disabled(!snapshot.hasNotifications)
        }
    }

    private var notificationMenuSnapshot: NotificationMenuSnapshot {
        notificationStore.notificationMenuSnapshot
    }

    private func notificationMenuItemTitle(for notification: TerminalNotification) -> String {
        let tabTitle = appDelegate.tabTitle(for: notification.tabId)
        return MenuBarNotificationLine(notification: notification, tabTitle: tabTitle).menuTitle
    }

    private func openNotificationFromMainMenu(_ notification: TerminalNotification) {
        _ = appDelegate.openTerminalNotification(notification)
    }
}
