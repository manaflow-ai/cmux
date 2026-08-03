public import Foundation

/// The sidebar identity of one workspace group: the group, the workspace that
/// backs its header row, and the name that row renders.
public struct CommandPaletteWorkspaceGroupAnchor: Equatable, Sendable {
    /// The group's id.
    public let groupId: UUID
    /// The workspace whose row the group header replaces.
    public let anchorWorkspaceId: UUID
    /// The group name shown on the header row.
    public let name: String

    /// Creates a group anchor descriptor.
    public init(groupId: UUID, anchorWorkspaceId: UUID, name: String) {
        self.groupId = groupId
        self.anchorWorkspaceId = anchorWorkspaceId
        self.name = name
    }
}

/// Resolves what "Rename Workspace" edits for the focused workspace.
///
/// A group's anchor workspace has no visible name of its own: the sidebar draws
/// the group name on that row and the anchor's own title (seeded from the
/// group's name at creation and never resynced) stays hidden. Renaming the
/// anchor workspace there changes nothing the user can see, and the prefilled
/// text is a stale group name (issue #9199). So when the focused workspace is a
/// group anchor, the rename targets the group, matching that row's "Rename
/// Group..." context menu item.
public enum CommandPaletteWorkspaceRenameResolver {
    /// Returns the rename target for the focused workspace.
    ///
    /// - Parameters:
    ///   - focusedWorkspaceId: The currently selected workspace.
    ///   - focusedWorkspaceName: Its display name, used when it is not an anchor.
    ///   - groupAnchors: Every group's anchor descriptor.
    public static func target(
        focusedWorkspaceId: UUID,
        focusedWorkspaceName: String,
        groupAnchors: [CommandPaletteWorkspaceGroupAnchor]
    ) -> CommandPaletteRenameTarget {
        if let anchor = groupAnchors.first(where: { $0.anchorWorkspaceId == focusedWorkspaceId }) {
            return CommandPaletteRenameTarget(
                kind: .workspaceGroup(groupId: anchor.groupId),
                currentName: anchor.name
            )
        }
        return CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: focusedWorkspaceId),
            currentName: focusedWorkspaceName
        )
    }
}
