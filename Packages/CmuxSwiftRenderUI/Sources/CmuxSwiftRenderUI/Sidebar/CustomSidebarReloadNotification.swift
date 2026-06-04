import Foundation

public extension Notification.Name {
    /// Posted by the host app when mounted custom sidebars should re-read their files.
    static let customSidebarReloadRequested = Notification.Name("cmux.customSidebarReloadRequested")
}
