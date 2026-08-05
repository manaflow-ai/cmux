#if canImport(UIKit) && DEBUG
@preconcurrency import UserNotifications

/// Drives a real iOS notification for the App Store notifications screenshot.
///
/// `UserNotifications` is an SDK callback boundary. State and request creation
/// remain main-actor isolated while its async APIs perform the system work.
@MainActor
final class ScreenshotNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private var fired = false
    private var requestTask: Task<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestTask = Task {
            guard !Task.isCancelled,
                  (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
            else { return }
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
            try? await center.add(
                UNNotificationRequest(
                    identifier: "cmux-screenshot-agent",
                    content: content,
                    trigger: trigger
                )
            )
        }
    }

    isolated deinit {
        requestTask?.cancel()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
#endif
