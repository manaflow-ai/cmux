#if os(iOS)
import Foundation
import UserNotifications

/// Seam over the system notification center for the inline-reply failure
/// notice, so a reply the app could not deliver is never dropped silently.
///
/// The notice is SCHEDULED when a reply parks (just past the reply's delivery
/// lifetime) and CANCELLED on a successful send. Scheduling up front — instead
/// of posting at the moment the expiry is detected — is what makes the notice
/// survive suspension: iOS fires it on time even when the process was killed
/// before it could observe the expiry. The production conformance is
/// ``SystemReplyFailureNotifier``; tests inject a fake to assert scheduling,
/// immediate delivery, and cancellation.
public protocol ReplyFailureNoticing: Sendable {
    /// Schedule (or replace) the failure notice.
    /// - Parameters:
    ///   - delay: Seconds until the notice fires unless cancelled.
    ///   - replyText: The user's reply text, echoed so they can retype it.
    func schedule(after delay: TimeInterval, replyText: String) async

    /// Deliver the failure notice immediately (the reply was proven
    /// undeliverable before its lifetime elapsed).
    /// - Parameter replyText: The user's reply text, echoed so they can retype it.
    func deliverNow(replyText: String) async

    /// Cancel a scheduled, not-yet-fired notice (the reply was delivered).
    func cancel() async
}

/// Production ``ReplyFailureNoticing`` backed by `UNUserNotificationCenter`.
/// One notice exists at a time (a newer parked reply replaces the older
/// reply's notice), matching the single-slot pending-reply lane.
public struct SystemReplyFailureNotifier: ReplyFailureNoticing {
    static let requestIdentifier = "cmux.push.reply.failure"
    /// Keep the echoed reply readable in a banner without flooding it.
    private static let echoLimit = 120

    public init() {}

    public func schedule(after delay: TimeInterval, replyText: String) async {
        guard Self.canUseNotificationCenter else { return }
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(delay, 1),
            repeats: false
        )
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.requestIdentifier,
                content: Self.content(replyText: replyText),
                trigger: trigger
            )
        )
    }

    public func deliverNow(replyText: String) async {
        guard Self.canUseNotificationCenter else { return }
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.requestIdentifier,
                content: Self.content(replyText: replyText),
                trigger: nil
            )
        )
    }

    public func cancel() async {
        guard Self.canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.requestIdentifier]
        )
    }

    private static func content(replyText: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "mobile.push.reply.failure.title",
            defaultValue: "Reply not sent",
            bundle: .module
        )
        let echo = replyText.count > echoLimit
            ? replyText.prefix(echoLimit) + "…"
            : replyText
        content.body = String(
            format: String(
                localized: "mobile.push.reply.failure.body",
                defaultValue: "“%@” didn’t reach your Mac. Open cmux to send it again.",
                bundle: .module
            ),
            String(echo)
        )
        content.sound = .default
        return content
    }

    private static var canUseNotificationCenter: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
#endif
