#if canImport(UIKit) && DEBUG
@preconcurrency import UserNotifications

/// Drives a realistic set of iOS notifications for screenshot capture.
///
/// Safety: `UNUserNotificationCenter` retains the delegate and may call it from
/// framework-managed concurrency contexts; this object guards its only mutable
/// state on the main screenshot flow before the notification request is queued.
final class ScreenshotNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var fired = false

    func fire() {
        guard !fired else { return }
        fired = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()

            let notifications = [
                (
                    identifier: "cmux-screenshot-input",
                    title: String(
                        localized: "mobile.screenshot.notification.input.title",
                        defaultValue: "Codex needs your input",
                        bundle: .main
                    ),
                    body: String(
                        localized: "mobile.screenshot.notification.input.body",
                        defaultValue: "Approve the command to keep work moving.",
                        bundle: .main
                    )
                ),
                (
                    identifier: "cmux-screenshot-finished",
                    title: String(
                        localized: "mobile.screenshot.notification.finished.title",
                        defaultValue: "Claude finished",
                        bundle: .main
                    ),
                    body: String(
                        localized: "mobile.screenshot.notification.finished.body",
                        defaultValue: "The login crash fix is ready for review.",
                        bundle: .main
                    )
                ),
                (
                    identifier: "cmux-screenshot-tests",
                    title: String(
                        localized: "mobile.screenshot.notification.tests.title",
                        defaultValue: "Tests need attention",
                        bundle: .main
                    ),
                    body: String(
                        localized: "mobile.screenshot.notification.tests.body",
                        defaultValue: "2 checks failed in cmux. Tap to open the workspace.",
                        bundle: .main
                    )
                ),
            ]

            for (index, notification) in notifications.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = .default
                content.threadIdentifier = "cmux-screenshot-agent-events"
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: 0.7 * Double(index + 1),
                    repeats: false
                )
                center.add(UNNotificationRequest(
                    identifier: notification.identifier,
                    content: content,
                    trigger: trigger
                ))
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
#endif
