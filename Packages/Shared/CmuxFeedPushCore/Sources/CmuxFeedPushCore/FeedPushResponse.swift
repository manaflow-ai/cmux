/// What the app does with one banner response.
public enum FeedPushResponse: Hashable, Sendable {
    /// Send this op (an answer from the banner).
    case send(CloudOpKey)
    /// Open the item in the app (a tap, Open on Mac, a choice, or an empty reply).
    case open(item: String)
    /// Not a feed push.
    case ignore

    /// The op to send, with an idempotency key stable per (item, action), so a
    /// repeated delivery of the same tap is applied once by the owner.
    public struct CloudOpKey: Hashable, Sendable {
        public var item: String
        public var answer: FeedAnswer
        public var idempotencyKey: String

        public var op: CloudOp { .answer(item: item, answer: answer, idempotencyKey: idempotencyKey) }
    }

    public init(actionIdentifier: String, userText: String?, userInfo: [AnyHashable: Any]) {
        guard let payload = FeedPushPayload(userInfo: userInfo) else { self = .ignore; return }
        guard let action = FeedPushAction(rawValue: actionIdentifier),
              let answer = FeedAnswer(action: action, text: userText) else {
            self = .open(item: payload.item)
            return
        }
        self = .send(CloudOpKey(item: payload.item, answer: answer,
                                idempotencyKey: "feed-answer-\(payload.item)-\(action.rawValue)"))
    }
}
