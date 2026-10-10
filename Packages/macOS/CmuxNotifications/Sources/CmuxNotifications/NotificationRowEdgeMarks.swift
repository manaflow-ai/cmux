import Foundation

/// What the thin bars on a notification row's two edges show.
///
/// A row whose workspace has a color carries that color on its leading edge, the way the
/// workspace's sidebar row does, so the unread mark moves to the trailing edge instead of
/// replacing it. A row without a color keeps the unread mark on the leading edge.
public struct NotificationRowEdgeMarks: Sendable, Equatable {
    public enum Mark: Sendable, Equatable {
        case none
        case workspaceColor
        case unread
    }

    public let leading: Mark
    public let trailing: Mark

    public init(hasWorkspaceColor: Bool, isRead: Bool) {
        let unread: Mark = isRead ? .none : .unread
        if hasWorkspaceColor {
            leading = .workspaceColor
            trailing = unread
        } else {
            leading = unread
            trailing = .none
        }
    }
}
