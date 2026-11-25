import AppKit
import CmuxNotifications
import Foundation

extension AppDelegate {
    /// While the notifications popover is up, the workspace digit shortcuts open its rows, which
    /// show these numbers while the modifier is held. The popover never takes key, so the event
    /// arrives as a workspace shortcut. Returns whether the popover took it: a digit with no row
    /// still counts, so it does not fall through and switch workspaces behind the popover.
    ///
    /// The digit picks among the rows the popover drew, so it opens the notification it labelled
    /// even when one has arrived or gone since, and does nothing if that one is gone. Only the
    /// popover over the event's window takes it; another window's digits switch its workspaces.
    func openNotificationsPopoverRow(forDigit digit: Int, event: NSEvent) -> Bool {
        // The same window whose workspaces the digit would switch, so the two always agree.
        guard let window = preferredMainWindowContextForShortcutRouting(event: event)?.window
                ?? event.window ?? NSApp.keyWindow,
              let displayed = titlebarAccessoryController.shownNotificationsPopoverRowIds(
                  forWindowNumber: window.windowNumber
              ),
              let notificationStore else { return false }
        if let notification = NotificationListShortcutDigit.item(
            forDigit: digit,
            displayed: displayed,
            current: notificationStore.notifications,
            id: \.id
        ) {
            _ = openTerminalNotification(notification)
            dismissNotificationsPopoverIfShown()
        }
        return true
    }
}
