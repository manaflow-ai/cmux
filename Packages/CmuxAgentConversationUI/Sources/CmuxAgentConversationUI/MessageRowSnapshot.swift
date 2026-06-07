/// An immutable, value-typed description of one rendered chat row.
///
/// The view model projects a ``Conversation`` into an array of these so the row
/// views receive only values plus closures, never a store reference. This is
/// the snapshot-boundary contract that keeps an orthogonal model change from
/// invalidating every row in a `LazyVStack` (see the repo's snapshot-boundary
/// rule). A tool call and its paired result collapse into a single
/// ``MessageRowSnapshot/Kind/toolCall(_:)`` row; everything else is a
/// ``MessageRowSnapshot/Kind/message(_:)`` bubble.
public struct MessageRowSnapshot: Identifiable, Hashable, Sendable {
    /// What a row renders.
    public enum Kind: Hashable, Sendable {
        /// A plain message bubble (user / assistant text, reasoning, system).
        case message(MessageBubbleSnapshot)

        /// A tool call paired with its result (if the result has arrived).
        case toolCall(ToolCallSnapshot)
    }

    /// A stable identity for the row, used as the `ForEach` id.
    public let id: String

    /// The content this row renders.
    public let kind: Kind

    /// Creates a row snapshot.
    ///
    /// - Parameters:
    ///   - id: A stable identity for the row.
    ///   - kind: The content this row renders.
    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}
