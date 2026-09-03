/// The tier-relative move actions available for one workspace.
public struct WorkspaceTierMoveAvailability: Equatable, Sendable {
    /// Whether the workspace can move to the top of its pin tier.
    public let canMoveToTop: Bool

    /// Whether the workspace can move to the bottom of its pin tier.
    public let canMoveToBottom: Bool

    /// Creates the availability for one workspace's tier-relative move actions.
    ///
    /// - Parameters:
    ///   - canMoveToTop: Whether move-to-top would change the workspace order.
    ///   - canMoveToBottom: Whether move-to-bottom would change the workspace order.
    public init(canMoveToTop: Bool, canMoveToBottom: Bool) {
        self.canMoveToTop = canMoveToTop
        self.canMoveToBottom = canMoveToBottom
    }
}
