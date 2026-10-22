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
        let content = Self.opened(request.content, keys: PushKeys.current()) ?? request.content
        contentHandler(content)
        self.contentHandler = nil
    }

    /// Out of time: the banner APNs brought.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let generic { contentHandler(generic) }
        contentHandler = nil
    }

    /// The opened notification, or nil to keep `content` as it came.
    static func opened(_ content: UNNotificationContent, keys: PushKeys?) -> UNNotificationContent? {
        guard let sealed = SealedPush(userInfo: content.userInfo), let keys,
              let payload = try? sealed.open(trust: keys.trust(), keys: keys) else { return nil }
        let out = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let banner = PushBanner(payload: payload)
        out.title = banner.title
        out.subtitle = banner.subtitle ?? ""
        out.body = banner.body
        out.categoryIdentifier = payload.category.rawValue
        out.threadIdentifier = payload.threadIdentifier
        out.targetContentIdentifier = payload.threadIdentifier
        if payload.kind.isAsk { out.interruptionLevel = .timeSensitive }
        var info = content.userInfo
        info.merge(payload.userInfo) { _, new in new }
        out.userInfo = info
        return out
    }
}
