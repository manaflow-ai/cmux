import CmuxMobileNotifications
import Foundation
import UserNotifications

/// Opens sealed pushes (PROTOCOL.md "Sealed notify", verify/notifications-trust.md).
///
/// The Mac sealed the notification to this phone's push key and signed it
/// with its identity key; APNs and the cmux service saw only a generic banner.
/// Here the signature is checked against the key this phone pinned for that
/// Mac, the box is opened, and the notification gets its real text, category,
/// thread and the v2 payload the buttons and the long-press view read. Anything
/// that does not check out keeps the generic banner.
///
/// Agent Alarms: an opened push of an agent stuck on the person (a permission
/// request, a question, a terminal agent waiting, an agent that stopped) also
/// rings an AlarmKit alarm, through the same 30 second gate the app uses. This is
/// the path that rings while cmux is in the background, suspended or not running.
final class NotificationService: UNNotificationServiceExtension {
    /// The handler, called once: by the finished work or by the expiry, whichever is first.
    private final class Delivery: @unchecked Sendable { // crash-allow: lock-guarded
        private let lock = NSLock()
        private var handler: ((UNNotificationContent) -> Void)?

        init(_ handler: @escaping (UNNotificationContent) -> Void) { self.handler = handler }

        func deliver(_ content: UNNotificationContent) {
            let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
                defer { self.handler = nil }
                return self.handler
            }
            handler?(content)
        }
    }

    private var delivery: Delivery?
    private var generic: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let delivery = Delivery(contentHandler)
        self.delivery = delivery
        generic = request.content
        let keys = PushKeys.current()
        let service = ServicePush()
        // The pairing key remains after sign-out, but the active-account
        // marker does not. Strip a queued old-account push before decrypting.
        let content = service.withheld(request.content, keys: keys)
            ?? service.opened(request.content, keys: keys)
            ?? service.inert(request.content, trust: keys?.trust())
            ?? service.categorized(request.content)
            ?? request.content
        // A chat muted on this phone (Mute Chat Notifications) arrives quietly.
        let mutes = PushChatMutes.live()
        let shown = mutes.quieted(content) ?? content
        guard let payload = service.alarmPayload(shown, muted: mutes.mutes(shown.userInfo)) else {
            return delivery.deliver(shown)
        }
        let sendable = UncheckedContent(content: shown)
        Task {
            await AgentAlarms.handle(payload, source: .serviceExtension)
            delivery.deliver(sendable.content)
        }
    }

    /// Out of time: the banner APNs brought.
    override func serviceExtensionTimeWillExpire() {
        if let delivery, let generic { delivery.deliver(generic) }
        delivery = nil
    }
}

/// The finished content crossing into the alarm task; nothing mutates it after.
private struct UncheckedContent: @unchecked Sendable { // crash-allow: immutable after the hand-off
    let content: UNNotificationContent
}
