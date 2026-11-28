import Foundation

/// What is being dragged in the sidebar.
public nonisolated enum DragPayload: Hashable, Sendable {
    /// A selection of workspaces being repositioned.
    case workspaces([WorkspaceID])
    /// A group being repositioned as one block.
    case group(GroupID)
    /// A listed sidebar document item (a link, tab or app row); only the
    /// sidebar document's drag moves it.
    case item(String)
}
