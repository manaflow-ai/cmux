#if canImport(UIKit) && DEBUG
import UserNotifications

/// Drives a real iOS notification for the App Store notifications screenshot.
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
            let content = UNMutableNotificationContent()
            content.title = String(
                localized: "mobile.screenshot.notification.title",
                defaultValue: "Agent needs your input",
                bundle: .main
            )
            content.body = String(
                localized: "mobile.screenshot.notification.body",
                defaultValue: "Claude is asking: which database should I use, Postgres or SQLite?",
                bundle: .main
            )
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.6, repeats: false)
            center.add(UNNotificationRequest(
                identifier: "cmux-screenshot-agent",
                content: content,
                trigger: trigger
            ))
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
