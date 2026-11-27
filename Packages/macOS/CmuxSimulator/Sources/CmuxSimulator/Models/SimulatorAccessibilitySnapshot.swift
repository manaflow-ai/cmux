/// A bounded accessibility tree for the current simulated foreground app.
public struct SimulatorAccessibilitySnapshot: Codable, Equatable, Sendable {
    /// Root accessibility elements.
    public let roots: [SimulatorAccessibilityNode]
    /// The display size used to map frames back to touch coordinates.
    public let display: SimulatorDisplayMetadata
    /// Total serialized elements across recursive and point-discovered roots.
    public let nodeCount: Int
    /// Whether the worker stopped traversal at its node or depth limit.
    public let isTruncated: Bool

    /// Creates an accessibility snapshot.
    public init(
        roots: [SimulatorAccessibilityNode],
        display: SimulatorDisplayMetadata,
        nodeCount: Int? = nil,
        isTruncated: Bool = false
    ) {
        self.roots = roots
        self.display = display
        self.nodeCount = nodeCount ?? roots.reduce(0) { $0 + $1.subtreeNodeCount }
        self.isTruncated = isTruncated
    }
}
