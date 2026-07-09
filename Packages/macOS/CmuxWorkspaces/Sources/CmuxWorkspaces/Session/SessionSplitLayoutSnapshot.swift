/// A persisted split node in a workspace layout snapshot: its orientation,
/// divider position, and two child subtrees.
public struct SessionSplitLayoutSnapshot: Codable, Sendable {
    /// Orientation of the split.
    public var orientation: SessionSplitOrientation
    /// Normalized divider position in `0...1`.
    public var dividerPosition: Double
    /// The first (leading/top) child subtree.
    public var first: SessionWorkspaceLayoutSnapshot
    /// The second (trailing/bottom) child subtree.
    public var second: SessionWorkspaceLayoutSnapshot

    /// Creates a persisted split snapshot.
    public init(
        orientation: SessionSplitOrientation,
        dividerPosition: Double,
        first: SessionWorkspaceLayoutSnapshot,
        second: SessionWorkspaceLayoutSnapshot
    ) {
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }
}
