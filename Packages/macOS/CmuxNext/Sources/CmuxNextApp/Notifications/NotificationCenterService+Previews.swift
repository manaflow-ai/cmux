import CmuxNextDaemon
import CmuxNextSettings
import CoreGraphics

extension NotificationCenterService {
    /// The banner's text: the poster's own body, else an agent's last message (`preview`, a
    /// finished turn) as `notifications.showPreviews` allows: always, only while the screen is
    /// unlocked (default, like macOS), or never.
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
