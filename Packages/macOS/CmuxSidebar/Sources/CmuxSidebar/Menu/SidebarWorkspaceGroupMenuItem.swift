public import Foundation

/// One workspace group offered by the "Move to Group" submenu of a sidebar
/// row's context menu.
///
/// A `Sendable` value snapshot of an app-side group, built once per parent
/// body evaluation and passed into the group context-menu package view. The
/// view diffs the list by ``id`` and renders ``name``; it never reads the
/// app's live group store.
public struct SidebarWorkspaceGroupMenuItem: Identifiable, Equatable, Sendable {
    /// The group's stable identifier.
    public let id: UUID
    /// The group's display name.
    public let name: String

    /// Creates a group menu item.
    /// - Parameters:
    ///   - id: The group's identifier.
    ///   - name: The group's display name.
    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}
