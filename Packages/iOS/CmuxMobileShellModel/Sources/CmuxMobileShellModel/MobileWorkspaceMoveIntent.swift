/// The Mac-facing workspace move request derived from a mobile drop.
public struct MobileWorkspaceMoveIntent: Equatable, Sendable {
    /// The target group, or `nil` to make the workspace ungrouped.
    public var groupID: MobileWorkspaceGroupPreview.ID?
    /// The workspace that should follow the dragged workspace, or `nil` to append.
    public var beforeWorkspaceID: MobileWorkspacePreview.ID?
    /// Whether this move represents a group header/top-level group row.
    public var movesGroup: Bool

    /// Creates a move intent.
    /// - Parameters:
    ///   - groupID: The target group, or `nil` to ungroup.
    ///   - beforeWorkspaceID: The workspace that should follow the dragged workspace.
    ///   - movesGroup: Whether the dragged row is a group header.
    public init(
        groupID: MobileWorkspaceGroupPreview.ID?,
        beforeWorkspaceID: MobileWorkspacePreview.ID?,
        movesGroup: Bool = false
    ) {
        self.groupID = groupID
        self.beforeWorkspaceID = beforeWorkspaceID
        self.movesGroup = movesGroup
    }
}
