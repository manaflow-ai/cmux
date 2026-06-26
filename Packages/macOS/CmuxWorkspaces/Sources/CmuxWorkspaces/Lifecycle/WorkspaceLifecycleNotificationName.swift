public import Foundation

/// Workspace-lifecycle `NotificationCenter` names owned by the workspace domain.
///
/// These are imperative-refresh signals posted by the app's workspace/group
/// state when a value the window chrome caches changes. They stay
/// `NotificationCenter`-delivered on purpose: each is consumed synchronously by
/// SwiftUI/AppKit chrome in the same MainActor turn as the post, so an
/// `AsyncStream` hop would let later mutations interleave before the dependent
/// surface refreshes. The wire shape (each raw name string) is byte-identical to
/// the legacy declarations these were lifted from.
extension Notification.Name {
    /// Posted when an existing workspace group's `name` changes (rename). The
    /// imperatively-cached window-chrome surfaces (custom title bar in
    /// `ContentView`, toolbar command label in `WindowToolbarController`) read
    /// a grouped anchor's displayed name from `group.name` and refresh on this.
    public static let workspaceGroupNameDidChange = Notification.Name("cmux.workspaceGroupNameDidChange")

    /// Posted when a workspace's current working directory changes. Window-title
    /// and directory-dependent chrome re-read the workspace's cwd on this.
    public static let workspaceCurrentDirectoryDidChange = Notification.Name("cmux.workspaceCurrentDirectoryDidChange")

    /// Posted when the tab manager's focus-history revision changes. Focus-history
    /// menus and accessories invalidate and rebuild on this.
    public static let tabManagerFocusHistoryRevisionDidChange = Notification.Name("cmux.tabManagerFocusHistoryRevisionDidChange")
}
