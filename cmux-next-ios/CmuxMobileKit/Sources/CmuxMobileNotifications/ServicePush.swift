import Foundation
import UserNotifications

/// What the Notification Service Extension does with a delivered push
/// (`NotificationService`): open a sealed one into its real banner, category
/// and v2 payload, or make an unsealed one from a sealing Mac inert. Shared so
/// DEBUG builds can run the very same code for a push `xcrun simctl push`
/// delivered, which never runs a service extension in the simulator.
public struct ServicePush: Sendable {
    public init() {}

    /// An unsealed push claiming to come from a Mac that seals to this phone
    /// (PR B security review H1): not its own, so the generic banner and no
    /// buttons. Nil for anything else.
    public func inert(_ content: UNNotificationContent, trust: PushTrust?) -> UNNotificationContent? {
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
    public func opened(_ content: UNNotificationContent, keys: PushKeys?) -> UNNotificationContent? {
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
