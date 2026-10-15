import CmuxNextDaemon
import CoreGraphics

/// When a banner shows what the agent said (its last message), named like macOS's own Show
/// Previews. Fixed at `whenUnlocked` until the `notifications.showPreviews` setting lands.
nonisolated enum NotificationPreviews: String, Hashable, Sendable, CaseIterable {
    case always
    /// Not while the screen is locked (default).
    case whenUnlocked
    case never
}

extension NotificationCenterService {
    /// The banner's text: the poster's own body, else an agent's last message (`preview`, a
    /// finished turn) as `previews` allows: always, only while the screen is unlocked (default,
    /// like macOS), or never.
    nonisolated static func bannerBody(_ notification: DaemonNotification, previews: NotificationPreviews,
                                       screenLocked: Bool) -> String {
        guard notification.body.isEmpty, let preview = notification.preview, !preview.isEmpty else { return notification.body }
        switch previews {
        case .always: return preview
        case .whenUnlocked: return screenLocked ? "" : preview
        case .never: return ""
        }
    }
}

/// The login session's screen lock, as the window server reports it.
nonisolated enum ScreenLock {
    static var isLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
