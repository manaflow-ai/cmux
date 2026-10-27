/// A subscription to a ``VisibilityNode``'s flips. The node holds it weakly: releasing the token
/// ends the subscription and releases its closure. ``cancel()`` ends it early.
@MainActor public final class VisibilitySubscription {
    /// The subscriber's name for diagnostics.
    public let owner: String
    let onFlip: @MainActor (Visibility) -> Void
    private weak var node: VisibilityNode?

    init(owner: String, node: VisibilityNode, onFlip: @escaping @MainActor (Visibility) -> Void) {
        self.owner = owner
        self.node = node
        self.onFlip = onFlip
    }

    /// Whether the subscription has not been cancelled.
    var isActive: Bool { node != nil }

    /// Ends the subscription now.
    public func cancel() {
        node?.remove(self)
        node = nil
    }
}
