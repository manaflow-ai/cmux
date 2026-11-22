import Foundation

/// What is being dragged in the sidebar.
public nonisolated enum DragPayload: Hashable, Sendable {
    /// A selection of workspaces being repositioned.
    case workspaces([WorkspaceID])
    /// A group being repositioned as one block.
    case group(GroupID)
}
