import CmuxNotifications
import Foundation

extension AppDelegate {
    /// While the notifications popover is up, the workspace digit shortcuts open its rows, which
    /// show these numbers while the modifier is held. The popover never takes key, so the event
    /// arrives as a workspace shortcut. Returns whether the popover took it: a digit with no row
    /// still counts, so it does not fall through and switch workspaces behind the popover.
    func openNotificationsPopoverRow(forDigit digit: Int) -> Bool {
        guard isNotificationsPopoverShown(), let notificationStore else { return false }
        let rows = notificationStore.notifications
        if let index = NotificationListShortcutDigit(rowCount: rows.count).rowIndex(forDigit: digit) {
            _ = openTerminalNotification(rows[index])
            dismissNotificationsPopoverIfShown()
        }
        return true
    }
}
