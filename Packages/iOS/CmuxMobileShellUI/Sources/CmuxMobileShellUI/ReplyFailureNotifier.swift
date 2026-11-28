#if os(iOS)
import Foundation
import UserNotifications

/// Seam over the system notification center for the inline-reply failure
/// notice, so a reply the app could not deliver is never dropped silently.
///
/// The notice is SCHEDULED when a reply parks (just past the reply's delivery
/// lifetime) and CANCELLED when that exact reply is delivered or superseded.
/// Scheduling up front — instead of posting at the moment the expiry is
/// detected — is what makes the notice survive suspension: iOS fires it on
/// time even when the process was killed before it could observe the expiry.
/// Every operation is keyed by the reply's id, so an older reply resolving
/// can never cancel a newer reply's notice. The notice body deliberately
/// never echoes the typed text: replies can carry commands or secrets, and
/// notification content outlives the lock-screen context it was typed in.
/// The production conformance is ``SystemReplyFailureNotifier``; tests inject
/// a fake to assert scheduling, immediate delivery, and cancellation.
public protocol ReplyFailureNoticing: Sendable {
    /// Schedule the failure notice for one reply.
    /// - Parameters:
    ///   - delay: Seconds until the notice fires unless cancelled.
    ///   - replyId: The reply this notice reports.
    func schedule(after delay: TimeInterval, replyId: String) async

    /// Deliver the failure notice immediately (the reply was proven
    /// undeliverable before its lifetime elapsed).
    /// - Parameter replyId: The reply this notice reports.
    func deliverNow(replyId: String) async

    /// Cancel one reply's scheduled, not-yet-fired notice (it was delivered
    /// or superseded by a newer reply).
    /// - Parameter replyId: The reply whose notice is void.
    func cancel(replyId: String) async
}

/// Production ``ReplyFailureNoticing`` backed by `UNUserNotificationCenter`,
/// one notification request per reply id.
public struct SystemReplyFailureNotifier: ReplyFailureNoticing {
    static let requestIdentifierPrefix = "cmux.push.reply.failure."

    public init() {}

    public func schedule(after delay: TimeInterval, replyId: String) async {
        guard Self.canUseNotificationCenter else { return }
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(delay, 1),
            repeats: false
        )
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.requestIdentifierPrefix + replyId,
                content: Self.content(),
                trigger: trigger
            )
        )
    }

    public func deliverNow(replyId: String) async {
        guard Self.canUseNotificationCenter else { return }
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.requestIdentifierPrefix + replyId,
                content: Self.content(),
                trigger: nil
            )
        )
    }

    public func cancel(replyId: String) async {
        guard Self.canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.requestIdentifierPrefix + replyId]
        )
    }

    private static func content() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "mobile.push.reply.failure.title",
            defaultValue: "Reply not sent",
            bundle: .module
        )
        content.body = String(
            localized: "mobile.push.reply.failure.body",
            defaultValue: "Your reply didn’t reach your Mac. Open cmux to send it again.",
            bundle: .module
        )
        content.sound = .default
        return content
    }

    private static var canUseNotificationCenter: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
#endif
