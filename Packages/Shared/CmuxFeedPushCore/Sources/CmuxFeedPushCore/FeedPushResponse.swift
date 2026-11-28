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

    /// FNV-1a 64-bit of the UTF-8 bytes, hex: short and stable across launches.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }

    public init(actionIdentifier: String, userText: String?, userInfo: [AnyHashable: Any]) {
        guard let payload = FeedPushPayload(userInfo: userInfo) else { self = .ignore; return }
        // Only an action the item's own category offers can answer it.
        guard let action = FeedPushAction(rawValue: actionIdentifier),
              let category = payload.category, category.actions.contains(action),
              let answer = FeedAnswer(action: action, text: userText) else {
            self = .open(item: payload.item)
            return
        }
        // Stable per (item, action, answer): a repeated delivery of one tap is
        // applied once; a different reply text is a different answer.
        var key = "feed-answer-\(payload.item)-\(action.rawValue)"
        if case .text(let text) = answer { key += "-" + Self.digest(text) }
        self = .send(CloudOpKey(item: payload.item, answer: answer, idempotencyKey: key))
    }
}
