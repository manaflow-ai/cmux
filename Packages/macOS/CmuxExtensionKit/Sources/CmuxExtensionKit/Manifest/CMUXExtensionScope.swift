import Foundation

public enum CmuxExtensionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceList
    case workspaceMetadata
    case surfaceMetadata
    case workspacePaths
    case notifications
    case networkPorts
    case pullRequests
    /// Native workspace groups, their display properties, and membership.
    case workspaceGroups
    /// Observed agent lifecycle and identity metadata for surfaces.
    case agentRuntime

    /// The API required to interpret this declared capability.
    var minimumAPIVersion: CmuxExtensionAPIVersion {
        switch self {
        case .workspaceGroups, .agentRuntime:
            return .sidebarV2_1
        case .workspaceList, .workspaceMetadata, .surfaceMetadata, .workspacePaths,
             .notifications, .networkPorts, .pullRequests:
            return .sidebarV2
        }
    }
}

public enum CmuxExtensionActionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case createWorkspace
    case selectWorkspace
    case closeWorkspace
    case createSurface
    case selectSurface
    case closeSurface
    case splitSurface
    case zoomSurface
    case navigateWorkspace
    case navigateSurface
    case openURL
    case createWorkspaceWithPath
    /// Show a workspace rename prompt or set its custom title.
    case renameWorkspace
    /// Show a surface rename prompt or set its custom title.
    case renameSurface
    /// Show a group rename prompt or set its name.
    case renameWorkspaceGroup
    /// Create a native group, including its anchor workspace if needed.
    case createWorkspaceGroup
    /// Change whether a workspace is pinned.
    case pinWorkspace
    /// Set a workspace's user-selected importance.
    case setWorkspaceImportance
    /// Expand or collapse a native workspace group.
    case collapseWorkspaceGroup
    /// Assign a workspace to a group or remove its group assignment.
    case moveWorkspaceToGroup
    /// Dissolve a group while retaining its workspaces.
    case ungroupWorkspaceGroup
    /// Delete a group and request native confirmation to close its workspaces.
    case deleteWorkspaceGroup
    /// Mark workspace notifications read or unread, or clear their latest item.
    case manageNotifications
    /// Mute or unmute a workspace's notifications.
    case muteWorkspace
    /// Set or clear a workspace's custom description.
    case editWorkspaceDescription
    /// Set or clear a workspace's custom color.
    case colorWorkspace
    /// Move a workspace within the native sidebar ordering.
    case reorderWorkspace

    /// The API required to interpret this declared capability.
    var minimumAPIVersion: CmuxExtensionAPIVersion {
        switch self {
        case .renameWorkspace, .renameSurface, .renameWorkspaceGroup, .createWorkspaceGroup, .pinWorkspace,
             .setWorkspaceImportance, .collapseWorkspaceGroup, .moveWorkspaceToGroup,
             .ungroupWorkspaceGroup, .deleteWorkspaceGroup, .manageNotifications,
             .muteWorkspace, .editWorkspaceDescription, .colorWorkspace, .reorderWorkspace:
            return .sidebarV2_1
        case .createWorkspace, .selectWorkspace, .closeWorkspace, .createSurface,
             .selectSurface, .closeSurface, .splitSurface, .zoomSurface,
             .navigateWorkspace, .navigateSurface, .openURL, .createWorkspaceWithPath:
            return .sidebarV2
        }
    }
}
