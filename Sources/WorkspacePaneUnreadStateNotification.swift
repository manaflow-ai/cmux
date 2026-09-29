import Foundation

/// Notification emitted when restored pane unread indicators change.
extension Notification.Name {
    static let workspacePaneUnreadStateDidChange = Notification.Name(
        "cmux.workspacePaneUnreadStateDidChange"
    )
}
