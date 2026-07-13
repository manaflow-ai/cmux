/// A recursive split node in a mirrored Mac workspace layout.
public struct MobileWorkspaceSplit: Codable, Equatable, Identifiable, Sendable {
    /// The stable Bonsplit split identifier.
    public var id: String
    /// The axis along which the children are arranged.
    public var orientation: MobileWorkspaceSplitOrientation
    /// The first child's fractional extent in the closed interval `0...1`.
    public var ratio: Double
    /// The first child in visual order.
    public var first: MobileWorkspaceLayoutNode
    /// The second child in visual order.
    public var second: MobileWorkspaceLayoutNode

    /// Creates a mirrored split node.
    /// - Parameters:
    ///   - id: The stable split identifier.
    ///   - orientation: The split axis.
    ///   - ratio: The first child's fractional extent.
    ///   - first: The first child.
    ///   - second: The second child.
    public init(
        id: String,
        orientation: MobileWorkspaceSplitOrientation,
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
