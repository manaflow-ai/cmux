import CoreGraphics

/// When a banner shows what the agent said (its last message), named like macOS's own Show
/// Previews: `notifications.showPreviews` in cmux.json. Shared by the settings that store it, the
/// daemon notification that carries the message and the app that posts the banner.
public enum NotificationPreviews: String, Hashable, Sendable, CaseIterable {
    /// On the lock screen too.
    case always
    /// Not while the screen is locked (default).
    case whenUnlocked
    /// Never: the banner says where and what state, not what was said.
    case never

    /// Whether the login session's screen is locked now, as the window server reports it.
    public static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
