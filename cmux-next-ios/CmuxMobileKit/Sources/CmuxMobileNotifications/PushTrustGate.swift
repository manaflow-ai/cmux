import Foundation

/// Decides what a push may do when a person acts on it (PR B security review H1).
///
/// A Mac that seals its pushes to this phone (it proved a box key after this
/// phone gave it a push key, `PushTrust.Mac.sealsPushes`) never has its
/// content read from the clear: an unsealed push claiming to come from it was
/// made by someone else (the service, or whoever holds the APNs key), and gets
/// no buttons and no content. A sealed push is opened again here, from the
/// box the service extension kept beside the content it wrote, so a `userInfo`
/// the service made up never counts. A push older than `maxAge` keeps its tap
/// (it opens the chat) but loses its buttons.
public struct PushTrustGate: Sendable {
    /// The key the service extension keeps the original sealed push under.
    public static let sealedKey = "cmuxMobileSealed"
    /// After this long a push's buttons stop acting (its tap still opens the app).
    public static let maxAge: TimeInterval = 15 * 60

    public let trust: PushTrust?
    public let keys: PushKeys?

    public init(trust: PushTrust?, keys: PushKeys?) {
        self.trust = trust
        self.keys = keys
    }

    /// This build's keys and trust record.
    public static func current() -> PushTrustGate {
        let keys = PushKeys.current()
        return PushTrustGate(trust: keys?.trust(), keys: keys)
    }

    /// What iOS shows for a notification: a sealed box acts only under the banner and
    /// category the service extension wrote from that very box (PR B review 2, B1). A push
    /// sent without `mutable-content` skips the extension, so its banner and buttons are
    /// whatever the sender chose.
    public struct Shown: Equatable, Sendable {
        public var title: String
        public var subtitle: String
        public var body: String
        public var category: String

        public init(title: String, subtitle: String, body: String, category: String) {
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.category = category
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Act on it: the payload to use (opened from its box when sealed).
        case trusted(PushPayload)
        /// Show it and open the app on a tap, but no button acts.
        case openOnly(PushPayload)
        /// Nothing to act on.
        case refused
    }

    /// What a notification's `userInfo`, shown as `shown`, may do at `now`. A sealed box
    /// acts only when what is shown is what the box says (`Shown`); nil `shown` (a caller
    /// with no delivered content) never lets a box act.
    public func verdict(userInfo: [AnyHashable: Any], shown: Shown?, now: Date = Date()) -> Verdict {
        if let sealedObject = userInfo[Self.sealedKey] as? [String: Any],
           let sealed = SealedPush(userInfo: [PushPayload.userInfoKey: sealedObject]) {
            guard let keys, let payload = try? sealed.open(trust: trust, keys: keys) else { return .refused }
            guard let shown, Self.matches(shown, payload) else { return .openOnly(PushPayload.routeOnly(payload)) }
            return fresh(payload, now: now) ? .trusted(payload) : .openOnly(payload)
        }
        guard let payload = PushPayload(userInfo: userInfo) else { return .refused }
        if let mac = payload.mac?.lowercased(), trust?.macs[mac]?.sealsPushes == true {
            // From a Mac that seals: an unsealed one is not its own. Opening the app does no harm.
            return .openOnly(PushPayload.routeOnly(payload))
        }
        return fresh(payload, now: now) ? .trusted(payload) : .openOnly(payload)
    }

    /// Whether `shown` is what the service extension writes for `payload`.
    static func matches(_ shown: Shown, _ payload: PushPayload) -> Bool {
        let banner = PushBanner(payload: payload)
        return shown.title == banner.title && shown.subtitle == (banner.subtitle ?? "") && shown.body == banner.body
            && shown.category == payload.category.rawValue
    }

    /// Whether `payload` is recent enough for its buttons to act.
    public func isFresh(_ payload: PushPayload, now: Date = Date()) -> Bool { fresh(payload, now: now) }

    func fresh(_ payload: PushPayload, now: Date) -> Bool {
        guard let posted = payload.postedAt else { return true }
        return now.timeIntervalSince1970 - TimeInterval(posted) <= Self.maxAge
    }
}

extension PushPayload {
    /// Only what routes a tap: the Mac and the ids, never text another party wrote.
    public static func routeOnly(_ p: PushPayload) -> PushPayload {
        PushPayload(mac: p.mac, kind: p.kind, eventId: p.eventId, workspaceId: p.workspaceId, tabId: p.tabId, sessionId: p.sessionId,
                    conversationId: p.conversationId)
    }
}
