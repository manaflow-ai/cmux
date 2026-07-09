/// The in-progress reply a user is composing in response to a Stop event
/// (Claude finished a turn and is waiting for the next prompt). Held per feed
/// item by the feed panel and bound into `StopActionArea`'s text field.
public struct FeedStopDraft: Equatable {
    /// The reply text the user has typed so far.
    public var reply = ""

    /// Whether the draft is empty (no reply typed yet).
    public var isPristine: Bool {
        reply.isEmpty
    }

    /// Creates an empty stop-reply draft.
    public init() {}
}
