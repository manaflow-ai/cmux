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
}
