/// A complete, immutable snapshot of one workspace's panes and surface tabs.
public struct MobileWorkspaceLayout: Codable, Equatable, Sendable {
    /// The Mac-side pane layout revision.
    public let version: Int

    /// The focused pane identifier, when a pane has focus.
    public let focusedPaneID: String?

    /// The root of the recursive split tree.
    public let root: MobileWorkspaceLayoutNode

    /// Creates a workspace pane-layout snapshot.
    ///
    /// - Parameters:
    ///   - version: The Mac-side pane layout revision.
    ///   - focusedPaneID: The focused pane identifier, when any.
    ///   - root: The root of the recursive split tree.
    public init(version: Int, focusedPaneID: String?, root: MobileWorkspaceLayoutNode) {
        self.version = version
        self.focusedPaneID = focusedPaneID
        self.root = root
    }

    /// Adds the user-visible topology to a caller-provided hash.
    ///
    /// The signature includes split structure and orientation, pane and surface
    /// ordering, pane selection, and focused pane. It intentionally excludes
    /// divider ratios, the revision number, titles, and surface types so divider
    /// drags do not flood layout invalidation while structural changes still do.
    ///
    /// - Parameter hasher: The hash accumulator to update.
    public func hashTopology(into hasher: inout Hasher) {
        hasher.combine(focusedPaneID)
        root.hashTopology(into: &hasher)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case focusedPaneID = "focused_pane_id"
        case root
    }
}
