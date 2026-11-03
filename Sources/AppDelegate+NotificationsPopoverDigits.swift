import CmuxNotifications
import Foundation

extension AppDelegate {
    /// While the notifications popover is up, the workspace digit shortcuts open its rows, which
    /// show these numbers while the modifier is held. The popover never takes key, so the event
    /// arrives as a workspace shortcut. Returns whether the popover took it: a digit with no row
    /// still counts, so it does not fall through and switch workspaces behind the popover.
    ///
    /// The digit picks among the rows the popover drew, so it opens the notification it labelled
    /// even when one has arrived or gone since, and does nothing if that one is gone.
    func openNotificationsPopoverRow(forDigit digit: Int) -> Bool {
        guard isNotificationsPopoverShown(), let notificationStore else { return false }
        if let notification = NotificationListShortcutDigit.item(
            forDigit: digit,
            displayed: notificationsPopoverDrawnRowIds(),
            current: notificationStore.notifications,
            id: \.id
        ) {
            _ = openTerminalNotification(notification)
            dismissNotificationsPopoverIfShown()
        }
        return true
    }
}
