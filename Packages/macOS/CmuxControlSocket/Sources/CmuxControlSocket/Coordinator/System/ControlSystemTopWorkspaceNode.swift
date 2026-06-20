public import Foundation

/// One workspace row of a `system.top` / `system.memory` snapshot (the legacy
/// `v2TopWorkspaceNode` dictionary, minus the coordinator-minted refs and the
/// process-annotation fields the nonisolated `system.top` pipeline adds
/// afterward).
///
/// The app target builds these from live `Workspace` state behind
/// ``ControlSystemContext/controlSystemTopWorkspaceNode(workspaceID:index:selected:)``;
/// the coordinator shapes them into the byte-faithful payload dictionary that
/// the worker-lane annotation pipeline then enriches.
public struct ControlSystemTopWorkspaceNode: Sendable, Equatable {
    /// The workspace's identifier.
    public let workspaceID: UUID
    /// The workspace's index within its window's tab list.
    public let index: Int
    /// The workspace's display title.
    public let title: String
    /// The custom description, if any.
    public let description: String?
    /// Whether this is the window's selected workspace.
    public let isSelected: Bool
    /// Whether the workspace is pinned.
    public let isPinned: Bool
    /// The workspace's pane nodes, in pane order.
    public let panes: [ControlSystemTopPaneNode]
    /// The workspace's tag nodes, in display order then agent-PID-only
    /// fallback order.
    public let tags: [ControlSystemTopTagNode]

    /// Creates a workspace node.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's identifier.
    ///   - index: The index within the window's tab list.
    ///   - title: The display title.
    ///   - description: The custom description, if any.
    ///   - isSelected: Whether this is the selected workspace.
    ///   - isPinned: Whether the workspace is pinned.
    ///   - panes: The workspace's pane nodes.
    ///   - tags: The workspace's tag nodes.
    public init(
        workspaceID: UUID,
        index: Int,
        title: String,
        description: String?,
        isSelected: Bool,
        isPinned: Bool,
        panes: [ControlSystemTopPaneNode],
        tags: [ControlSystemTopTagNode]
    ) {
        self.workspaceID = workspaceID
        self.index = index
        self.title = title
        self.description = description
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.panes = panes
        self.tags = tags
    }
}
