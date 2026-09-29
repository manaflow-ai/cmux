import Foundation

/// An insertion point in the sidebar tree.
///
/// `index` counts siblings in the target container *after the moved items
/// are removed*. That makes a position independent of where the items came
/// from, so the same value works for drag, keyboard reorder, and the daemon.
public nonisolated struct DropPosition: Hashable, Sendable {
    public var section: SectionID
    /// Target group, or nil for the section's top level.
    public var group: GroupID?
    public var index: Int

    public init(section: SectionID, group: GroupID? = nil, index: Int) {
        self.section = section
        self.group = group
        self.index = index
    }
}

/// What a drag would do if released now.
public nonisolated enum DropTarget: Hashable, Sendable {
    /// Insert at a position; a live gap opens there.
    case position(DropPosition)
    /// Append into a collapsed group; its header highlights instead of a gap.
    case intoGroup(GroupID)
}

/// What collapses.
public nonisolated enum CollapseTarget: Hashable, Sendable {
    case section(SectionID)
    case group(GroupID)
}

/// User intents emitted by the sidebar. The App layer forwards them to the
/// owning daemon; `SidebarModel.apply(_:)` applies them locally (optimistic
/// update and the standalone mock).
public nonisolated enum SidebarIntent: Hashable, Sendable {
    /// Activate a workspace (the selection's primary item).
    case select(WorkspaceID)
    /// Move workspaces, in tree order, to a position. Covers reorder, moving
    /// into or out of groups, pinning, and unpinning.
    case reorder([WorkspaceID], to: DropPosition)
    /// Append workspaces to a group.
    case move([WorkspaceID], toGroup: GroupID)
    /// Move a group within its section. `index` excludes the group itself.
    case reorderGroup(GroupID, index: Int)
    /// Create a group holding the given workspaces. The UI mints the id.
    case createGroup(GroupID, name: String, color: SidebarColor, workspaces: [WorkspaceID])
    case renameGroup(GroupID, String)
    case setGroupColor(GroupID, SidebarColor)
    /// Dissolve a group, leaving its workspaces in place.
    case ungroup(GroupID)
    case toggleCollapse(CollapseTarget)
    case close([WorkspaceID])
    case rename(WorkspaceID, String)
    /// Set a swatch color (nil restores the default symbol icon).
    case setColor([WorkspaceID], SidebarColor?)
    case setIcon([WorkspaceID], WorkspaceIcon)
    case setPinned([WorkspaceID], Bool)
    /// New workspace on a machine (nil = the machine of the active workspace,
    /// else local), optionally inside a group.
    case newWorkspace(machine: MachineID?, group: GroupID?)
}
