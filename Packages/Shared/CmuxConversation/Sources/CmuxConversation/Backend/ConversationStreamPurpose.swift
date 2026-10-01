/// What a byte stream to a backend's host is for.
public enum ConversationStreamPurpose: Hashable, Sendable {
    /// The long-lived control connection (requests, events).
    case control
    /// One file upload or download; closed when the transfer ends.
    case transfer
}
