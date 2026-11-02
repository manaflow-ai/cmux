import CmuxMobileNotifications
import UserNotifications

/// Opens sealed pushes (PROTOCOL.md "Sealed notify", verify/notifications-trust.md).
///
/// The Mac sealed the notification to this phone's push key and signed it
/// with its identity key; APNs and the cmux service saw only a generic banner.
/// Here the signature is checked against the key this phone pinned for that
/// Mac, the box is opened, and the notification gets its real text, category,
/// thread and the v2 payload the buttons and the long-press view read. Anything
/// that does not check out keeps the generic banner.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var generic: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        generic = request.content
        let keys = PushKeys.current()
        let service = ServicePush()
        // The pairing key remains after sign-out, but the active-account
        // marker does not. Strip a queued old-account push before decrypting.
        let content = service.withheld(request.content, keys: keys)
            ?? service.opened(request.content, keys: keys)
            ?? service.inert(request.content, trust: keys?.trust())
            ?? request.content
        contentHandler(content)
        self.contentHandler = nil
    }

    /// Out of time: the banner APNs brought.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let generic { contentHandler(generic) }
        contentHandler = nil
    }
}
