import Foundation

/// Debug-only notification-feed fixture flags.
extension UITestConfig {
    /// Whether the deterministic production notification-feed preview is enabled.
    ///
    /// `CMUX_UITEST_NOTIFICATION_FEED_PREVIEW=1` bypasses sign-in and pairing and
    /// mounts the real tab/feed views with interactive sample notifications.
    public static var notificationFeedPreviewEnabled: Bool {
        notificationFeedPreviewEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func notificationFeedPreviewEnabled(from env: [String: String]) -> Bool {
        #if DEBUG
        return env["CMUX_UITEST_NOTIFICATION_FEED_PREVIEW"] == "1"
        #else
        return false
        #endif
    }
}
