import Foundation

/// Notification names bridging the keyboard-shortcut dispatch / Settings picker
/// (which have no direct `ContentView` reference) to the focused window's
/// `ContentView`, reusing the same window-targeted broadcast pattern as the
/// command palette request.
enum BoundCommandNotifications {
    /// Posted by dispatch to run a custom-bound command on a window.
    /// `object` is the target `NSWindow`; userInfo `commandId` is the command id.
    static let execute = Notification.Name("cmux.boundCommandExecute")
    static let commandIdKey = "commandId"

    /// Posted by the Settings picker host to request the bindable command list.
    /// `object` is the target `NSWindow`; userInfo `replyId` correlates the reply.
    static let catalogRequest = Notification.Name("cmux.bindableCommandCatalogRequest")
    /// Posted by `ContentView` in response. userInfo `replyId` + `descriptors`.
    static let catalogReply = Notification.Name("cmux.bindableCommandCatalogReply")
    static let replyIdKey = "replyId"
    static let descriptorsKey = "descriptors"
}
