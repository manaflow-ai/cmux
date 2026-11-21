import Foundation

/// What a notification row shows for its workspace color and its unread state.
///
/// The two never share a spot. The leading rail carries the workspace's color, the way the
/// workspace's sidebar row does, and stays empty without one. The unread mark is a dot in the
/// same place on every row, so in a list that mixes colored and plain workspaces it never moves.
public struct NotificationRowMarks: Sendable, Equatable {
    /// What the leading rail shows.
    public enum Rail: Sendable, Equatable {
        /// Nothing: the workspace has no color.
        case none
        /// The workspace's color.
        case workspaceColor
    }

    /// What the leading rail shows.
    public let rail: Rail
    /// Whether the row shows its unread dot.
    public let showsUnreadDot: Bool

    /// Creates the marks for a row.
    /// - Parameter hasWorkspaceColor: Whether the notification's workspace has a color.
    /// - Parameter isRead: Whether the notification has been read.
    public init(hasWorkspaceColor: Bool, isRead: Bool) {
        rail = hasWorkspaceColor ? .workspaceColor : .none
        showsUnreadDot = !isRead
    }
}
