/// What the app does with one banner response.
public enum FeedPushResponse: Hashable, Sendable {
    /// Send this intent (an answer or a read mark from the banner).
    case perform(FeedPushIntent)
    /// Open the item in the app (a tap, Open on Mac, a choice, or an empty reply).
    case open(item: String)
    /// Not a feed push.
    case ignore

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
        if action == .markRead {
            self = .perform(FeedPushIntent(item: payload.item, change: .read,
                                           idempotencyKey: FeedPushIntent.makeIdempotencyKey(item: payload.item, action: action)))
            return
        }
        guard let answer = FeedAnswer(action: action, text: userText) else {
            self = .open(item: payload.item)
            return
        }
        let text: String? = switch answer {
        case .text(let value), .verdict(_, .some(let value)): value
        default: nil
        }
        let key = FeedPushIntent.makeIdempotencyKey(item: payload.item, action: action, text: text)
        self = .perform(FeedPushIntent(item: payload.item, change: .answer(answer), idempotencyKey: key))
    }
}
