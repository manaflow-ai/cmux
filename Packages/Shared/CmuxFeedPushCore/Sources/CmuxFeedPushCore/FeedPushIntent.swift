/// What one banner action asks the feed owner to do, with an idempotency
/// key stable per (item, action, text): a repeated delivery of one tap is
/// applied once; a different reply text is a different intent.
public struct FeedPushIntent: Hashable, Sendable {
    public enum Change: Hashable, Sendable {
        /// `feed.answer` (origin `user`).
        case answer(FeedAnswer)
        /// `feed.read` of this item.
        case read
    }

    public var item: String
    public var change: Change
    public var idempotencyKey: String

    public init(item: String, change: Change, idempotencyKey: String) {
        self.item = item
        self.change = change
        self.idempotencyKey = idempotencyKey
    }

    /// Builds the stable key shared by banner actions and the in-app Feed
    /// surface. Text replies include a digest so two different responses to
    /// the same item remain distinct owner operations.
    public static func makeIdempotencyKey(item: String, action: FeedPushAction, text: String? = nil) -> String {
        var key = "feed-push-\(item)-\(action.rawValue)"
        guard action == .reply || action == .requestChanges, let text else { return key }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        key += "-\(String(hash, radix: 16))"
        return key
    }
}
