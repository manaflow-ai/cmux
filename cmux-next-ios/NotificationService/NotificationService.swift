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
        let content = Self.opened(request.content, keys: keys) ?? Self.inert(request.content, trust: keys?.trust()) ?? request.content
        contentHandler(content)
        self.contentHandler = nil
    }

    /// Out of time: the banner APNs brought.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let generic { contentHandler(generic) }
        contentHandler = nil
    }

    /// An unsealed push claiming to come from a Mac that seals to this phone
    /// (PR B security review H1): not its own, so the generic banner and no
    /// buttons. Nil for anything else.
    static func inert(_ content: UNNotificationContent, trust: PushTrust?) -> UNNotificationContent? {
        guard SealedPush(userInfo: content.userInfo) == nil, let payload = PushPayload(userInfo: content.userInfo),
              let mac = payload.mac?.lowercased(), trust?.macs[mac]?.sealsPushes == true else { return nil }
        let out = UNMutableNotificationContent()
        let banner = PushBanner.generic(macName: nil)
        out.title = banner.title
        out.body = banner.body
        out.categoryIdentifier = PushCategory.sealed.rawValue
        out.userInfo = PushPayload.routeOnly(payload).userInfo
        return out
    }

    /// The opened notification, or nil to keep `content` as it came.
    static func opened(_ content: UNNotificationContent, keys: PushKeys?) -> UNNotificationContent? {
        guard let sealed = SealedPush(userInfo: content.userInfo), let keys,
              let payload = try? sealed.open(trust: keys.trust(), keys: keys) else { return nil }
        let stale = !PushTrustGate(trust: nil, keys: nil).isFresh(payload)
        let out = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let banner = PushBanner(payload: payload)
        out.title = banner.title
        out.subtitle = banner.subtitle ?? ""
        out.body = banner.body
        // An old push replayed later: its text, no buttons.
        out.categoryIdentifier = stale ? PushCategory.sealed.rawValue : payload.category.rawValue
        out.threadIdentifier = payload.threadIdentifier
        out.targetContentIdentifier = payload.threadIdentifier
        if payload.kind.isAsk { out.interruptionLevel = .timeSensitive }
        var info = payload.userInfo
        // The box as it came: the app opens it again before any button acts,
        // so content written here can't be what a reply is built from.
        info[PushTrustGate.sealedKey] = content.userInfo[PushPayload.userInfoKey]
        out.userInfo = info
        return out
    }
}
