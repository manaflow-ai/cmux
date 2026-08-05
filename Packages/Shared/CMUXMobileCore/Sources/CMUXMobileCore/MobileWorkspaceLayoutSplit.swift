/// One branch split in a synced workspace layout.
public struct MobileWorkspaceLayoutSplit: Codable, Equatable, Sendable {
    /// The stable split identifier.
    public let id: String

    /// The axis along which this split divides its rectangle.
    public let orientation: MobileWorkspaceLayoutOrientation

    /// The first child's proportional share of the split rectangle.
    public let ratio: Double

    /// The first child node.
    public let first: MobileWorkspaceLayoutNode

    /// The second child node.
    public let second: MobileWorkspaceLayoutNode

    /// Creates a split snapshot.
    ///
    /// - Parameters:
    ///   - id: The stable split identifier.
    ///   - orientation: The split axis.
    ///   - ratio: The first child's proportional share.
    ///   - first: The first child node.
    ///   - second: The second child node.
    public init(
        id: String,
        orientation: MobileWorkspaceLayoutOrientation,
        ratio: Double,
        first: MobileWorkspaceLayoutNode,
        second: MobileWorkspaceLayoutNode
    ) {
        self.id = id
        self.orientation = orientation
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}
