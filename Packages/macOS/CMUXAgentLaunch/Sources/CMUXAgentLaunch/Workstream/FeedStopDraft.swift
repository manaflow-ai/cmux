import Foundation

/// Editable draft of the reply a user is composing in a feed stop-card.
///
/// Feed rows bind to this value via `@Binding` so the row can keep its in-progress
/// reply text without holding a reference to the live store. Because it is a pure
/// `Equatable` value, a row view diffs it against the previous draft and re-renders
/// only when the reply actually changes.
public struct FeedStopDraft: Equatable {
    /// The reply text the user is composing for the stop-card.
    public var reply = ""

    /// Whether the draft is untouched (its reply is still empty).
    public var isPristine: Bool {
        reply.isEmpty
    }

    /// Creates an empty draft with no composed reply.
    public init() {}
}
