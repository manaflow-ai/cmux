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

    /// The synthetic item count for notification-feed scroll-perf stress runs.
    ///
    /// `CMUX_UITEST_NOTIFICATION_FEED_PREVIEW_COUNT=<n>` replaces the curated
    /// five-item fixture with `n` deterministic synthetic items. `nil` when
    /// unset or unparseable; clamped to 1...10_000.
    public static var notificationFeedPreviewItemCount: Int? {
        notificationFeedPreviewItemCount(from: ProcessInfo.processInfo.environment)
    }

    static func notificationFeedPreviewItemCount(from env: [String: String]) -> Int? {
        #if DEBUG
        guard let raw = env["CMUX_UITEST_NOTIFICATION_FEED_PREVIEW_COUNT"],
              let count = Int(raw) else { return nil }
        return min(max(count, 1), 10_000)
        #else
        return nil
        #endif
    }

    /// Whether the preview auto-drives repeated scroll passes for profiling.
    ///
    /// `CMUX_UITEST_NOTIFICATION_FEED_PREVIEW_AUTOSCROLL=1` steps the feed list
    /// top-to-bottom-to-top with animated `scrollTo` hops, wrapped in
    /// `OSSignposter` intervals so Instruments traces can bracket each pass.
    public static var notificationFeedPreviewAutoScrollEnabled: Bool {
        notificationFeedPreviewAutoScrollEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func notificationFeedPreviewAutoScrollEnabled(from env: [String: String]) -> Bool {
        #if DEBUG
        return env["CMUX_UITEST_NOTIFICATION_FEED_PREVIEW_AUTOSCROLL"] == "1"
        #else
        return false
        #endif
    }
}
