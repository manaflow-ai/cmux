/// A branch in a mobile pane layout tree.
public struct MobilePaneSplit: Sendable, Equatable {
    /// The stable split identifier.
    public let id: String
    /// The axis along which this split divides its rectangle.
    public let orientation: MobilePaneSplitOrientation
    /// The first child's proportional share, clamped to `0.05...0.95`.
    public let ratio: Double
    /// The first child in depth-first layout order.
    public let first: MobilePaneLayout.Node
    /// The second child in depth-first layout order.
    public let second: MobilePaneLayout.Node

    /// Creates a split node.
    /// - Parameters:
    ///   - id: The stable split identifier.
    ///   - orientation: The split axis.
    ///   - ratio: The first child's proportional share.
    ///   - first: The first child node.
    ///   - second: The second child node.
    public init(
        id: String,
        orientation: MobilePaneSplitOrientation,
        ratio: Double,
        first: MobilePaneLayout.Node,
        second: MobilePaneLayout.Node
    ) {
        self.id = id
        self.orientation = orientation
        self.ratio = ratio.isFinite ? min(max(ratio, 0.05), 0.95) : 0.5
        self.first = first
        self.second = second
    }
}
