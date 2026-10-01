/// What a ``ConversationFeed`` delivers.
public enum FeedUpdate: Hashable, Sendable {
    /// Events to fold, from history or live. `hasOlder` is set when the
    /// update says whether older history remains.
    case events([ConversationEnvelope], hasOlder: Bool?)
    /// The connection was re-established; unconfirmed local messages should
    /// be sent again (with their same client identifiers).
    case reconnected
}
