/// Permission modes that can be returned from a feed permission notification
/// action.
public enum NotificationFeedPermissionMode: String, Sendable, Equatable {
    /// Allow the single requested action.
    case once

    /// Allow the requested action for the current session.
    case always

    /// Allow all matching actions.
    case all

    /// Bypass permissions for the current request family.
    case bypass

    /// Deny the requested action.
    case deny
}
