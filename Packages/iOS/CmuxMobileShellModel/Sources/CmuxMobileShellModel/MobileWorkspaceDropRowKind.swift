import Foundation

/// The semantic kind of a rendered workspace-list drop row.
public enum MobileWorkspaceDropRowKind: Equatable, Sendable {
    /// A group header representing the group's anchor workspace.
    case groupHeader(MobileWorkspaceGroupPreview.ID)
    /// A visible workspace row.
    case workspace(MobileWorkspacePreview.ID)

    /// A stable identity shared by frame preferences and overlays.
    public var stableID: String {
        switch self {
        case .groupHeader(let groupID):
            return "group.\(groupID.rawValue)"
        case .workspace(let workspaceID):
            return "workspace.\(workspaceID.rawValue)"
        }
    }
}
