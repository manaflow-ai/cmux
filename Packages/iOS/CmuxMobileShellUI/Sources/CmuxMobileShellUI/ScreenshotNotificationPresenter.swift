#if canImport(UIKit) && DEBUG
import UserNotifications

/// Drives a real iOS notification for the App Store notifications screenshots.
///
/// Two fixture modes, selected by `CMUX_UITEST_NOTIFICATION_BANNER`:
/// - `"1"`: agent-needs-input banner over the workspace list, fired quickly so
///   the in-app snapshot test captures it in the foreground.
/// - `"reply"`: agent-finished notification carrying a text-input Reply action,
///   scheduled with a longer fuse so the capture harness can lock the simulator
///   first and shoot the lock-screen inline-reply UI
///   (`ios/scripts/appstore-shots.sh lockshot`).
///
/// Safety: `UNUserNotificationCenter` retains the delegate and may call it from
/// framework-managed concurrency contexts; this object guards its only mutable
/// state on the main screenshot flow before the notification request is queued.
final class ScreenshotNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var fired = false

    func fire(mode: String = "1") {
        guard !fired else { return }
        fired = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            let delay: TimeInterval
            if mode == "reply" {
                // Mirrors the agent-finished push that supports inline reply.
                // The category is registered here (fixture-only) so the system
                // renders the reply text field on long-press, including on the
                // lock screen.
                let replyAction = UNTextInputNotificationAction(
                    identifier: "cmux.screenshot.reply.action",
                    title: String(
                        localized: "mobile.screenshot.notification.reply.action",
                        defaultValue: "Reply",
                        bundle: .main
                    ),
                    options: [],
                    textInputButtonTitle: String(
                        localized: "mobile.screenshot.notification.reply.send",
                        defaultValue: "Send",
                        bundle: .main
                    ),
                    textInputPlaceholder: String(
                        localized: "mobile.screenshot.notification.reply.placeholder",
                        defaultValue: "Message the agent…",
                        bundle: .main
                    )
                )
                let fixtureCategory = UNNotificationCategory(
                    identifier: "cmux.screenshot.reply",
                    actions: [replyAction],
                    intentIdentifiers: [],
                    options: []
                )
                // Merge with whatever the app already registered; replacing the
                // set would strip the live notification categories' actions for
                // the rest of the session.
                center.getNotificationCategories { existing in
                    center.setNotificationCategories(existing.union([fixtureCategory]))
                }
                content.title = String(
                    localized: "mobile.screenshot.notification.reply.title",
                    defaultValue: "Claude finished in workspace ~",
                    bundle: .main
                )
                content.subtitle = String(
                    localized: "mobile.screenshot.notification.reply.subtitle",
                    defaultValue: "cmux agent",
                    bundle: .main
                )
                content.body = String(
                    localized: "mobile.screenshot.notification.reply.body",
                    defaultValue: "Implemented the fix and opened the PR. Ready for your review — reply to continue.",
                    bundle: .main
                )
                content.categoryIdentifier = "cmux.screenshot.reply"
                // Long enough for the harness to lock the simulator after the
                // authorization grant, short enough to keep the run tight.
                delay = 6.0
            } else {
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
                delay = 0.6
            }
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
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
