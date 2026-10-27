/// A warm vote on a ``VisibilityNode`` (``VisibilityNode/warmVote(reason:)``): while it holds, the
/// hidden node's observers keep their values fresh in idle time, until ``release()``.
///
/// The vote keeps its node alive, and the node counts it, until the vote is released: call
/// ``release()`` when the reason ends (the hover leaves, the Ctrl-Tab switcher closes, the tab is no
/// longer a neighbor). A vote has no deinit work.
@MainActor public final class VisibilityWarmVote {
    /// Why the node is warm (``VisibilityNode/warmReasons``).
    public let reason: String
    private let id: UInt64
    private var node: VisibilityNode?

    init(id: UInt64, reason: String, node: VisibilityNode) {
        self.id = id
        self.reason = reason
        self.node = node
    }

    /// Whether ``release()`` ran.
    public var isReleased: Bool { node == nil }

    /// Ends this vote. The last vote's release makes the node cold, with one notice per subscriber.
    /// Idempotent.
    public func release() {
        guard let node else { return }
        self.node = nil
        node.releaseWarmVote(id)
    }
}
