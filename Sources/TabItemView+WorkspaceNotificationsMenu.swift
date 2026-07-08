import AppKit
import SwiftUI

extension TabItemView {
    @ViewBuilder
    func workspaceNotificationsContextMenu(_ targetIds: [UUID]) -> some View {
        Menu(String(localized: "contextMenu.notifications", defaultValue: "Notifications")) {
            let notificationItems = workspaceNotificationMenuItems(targetIds)
            if notificationItems.isEmpty {
                Button(String(localized: "contextMenu.notifications.empty", defaultValue: "No Notifications")) {}
                    .disabled(true)
            } else {
                ForEach(notificationItems) { notification in
                    Button(workspaceNotificationMenuTitle(notification)) {
                        openWorkspaceContextMenuNotification(notification)
                    }
                }
            }
        }
        .disabled(targetIds.isEmpty)
    }

    func workspaceNotificationMenuItems(_ targetIds: [UUID]) -> [TerminalNotification] {
        notificationStore.notifications(forTabIds: targetIds)
    }

    func workspaceNotificationMenuTitle(_ notification: TerminalNotification) -> String {
        let timeText = notification.createdAt.formatted(date: .abbreviated, time: .shortened)
        let title = workspaceNotificationMenuText(notification.title, limit: 80)
        let detail = workspaceNotificationMenuText(
            notification.body.isEmpty ? notification.subtitle : notification.body,
            limit: 120
        )
        let readPrefix = notification.isRead ? "" : "• "
        let firstLine = title.isEmpty
            ? "\(readPrefix)\(timeText)"
            : "\(readPrefix)\(timeText)  \(title)"
        guard !detail.isEmpty else { return firstLine }
        return "\(firstLine)\n\(detail)"
    }

    private func workspaceNotificationMenuText(_ value: String, limit: Int) -> String {
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let prefix = String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }

    func openWorkspaceContextMenuNotification(_ notification: TerminalNotification) {
        guard AppDelegate.shared?.openTerminalNotification(notification) == true else {
            NSSound.beep()
            return
        }
        refreshWorkspaceSnapshot(force: true)
    }
}
