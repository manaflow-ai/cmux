public import CmuxNextDesign

/// A sidebar group as Go to Workspace (Cmd-P) lists it: the active window's sidebar draws the
/// groups, so it is the source, not the daemon tree. The App builds one per group the sidebar
/// draws, in its order, and Go to Workspace makes a group row of each.
public nonisolated struct PaletteNavigationGroup: Hashable, Sendable {
    /// The group's id, as the sidebar keys it.
    public var id: String
    /// The group's name, the row's title.
    public var name: String
    /// The group's color, the row's ball; nil for a group with a custom color.
    public var color: GroupColor?
    /// Member workspace ids, in sidebar order.
    public var workspaceIDs: [String]

    /// - Parameters:
    ///   - id: The group's id.
    ///   - name: The group's name.
    ///   - color: The group's color, nil for none.
    ///   - workspaceIDs: Its workspaces' ids, in sidebar order.
    public init(id: String, name: String, color: GroupColor?, workspaceIDs: [String]) {
        self.id = id
        self.name = name
        self.color = color
        self.workspaceIDs = workspaceIDs
    }
}
