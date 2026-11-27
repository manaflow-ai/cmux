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
    /// Onto the middle of a loose workspace row: the dragged workspaces and
    /// that one become a new group. The row highlights; nothing moves.
    case ontoWorkspace(WorkspaceID)
}

/// What collapses.
public nonisolated enum CollapseTarget: Hashable, Sendable {
    case section(SectionID)
    case group(GroupID)
}
