/// What the app does with one banner response.
public enum FeedPushResponse: Hashable, Sendable {
    /// Send this intent (an answer or a read mark from the banner).
    case perform(FeedPushIntent)
    /// Open the item in the app (a tap, Open on Mac, a choice, or an empty reply).
    case open(item: String)
    /// Not a feed push.
    case ignore

    /// FNV-1a 64-bit of the UTF-8 bytes, hex: short and stable across launches.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// `categoryIdentifier` is the delivered content's category (the
    /// extension may have assigned it); an empty one falls back to
    /// `aps.category`.
    public init(actionIdentifier: String, userText: String?, categoryIdentifier: String = "",
                userInfo: [AnyHashable: Any]) {
        guard let payload = FeedPushPayload(userInfo: userInfo) else { self = .ignore; return }
        let category = FeedPushCategory(rawValue: categoryIdentifier) ?? payload.category
        // Only an action the item's own category offers can act on it.
        guard let action = FeedPushAction(rawValue: actionIdentifier), let category,
              category.actions.contains(action) else {
            self = .open(item: payload.item)
            return
        }
        var key = "feed-push-\(payload.item)-\(action.rawValue)"
        if action == .markRead {
            self = .perform(FeedPushIntent(item: payload.item, change: .read, idempotencyKey: key))
            return
        }
        guard let answer = FeedAnswer(action: action, text: userText) else {
            self = .open(item: payload.item)
            return
        }
        switch answer {
        case .text(let text), .verdict(_, .some(let text)): key += "-" + Self.digest(text)
        default: break
        }
        self = .perform(FeedPushIntent(item: payload.item, change: .answer(answer), idempotencyKey: key))
    }
}
