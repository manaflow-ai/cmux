import Foundation

public enum CmuxSidebarSplitDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

@_spi(CmuxHostTransport)
public enum CmuxSidebarAction: Codable, Equatable, Sendable {
    case createWorkspace(title: String?, workingDirectory: String?, select: Bool)
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case selectNextWorkspace
    case selectPreviousWorkspace
    case createTerminalSurface(workspaceID: UUID?)
    case createBrowserSurface(workspaceID: UUID?, url: String?)
    case selectSurface(workspaceID: UUID, surfaceID: UUID)
    case selectNextSurface
    case selectPreviousSurface
    case closeSurface(workspaceID: UUID, surfaceID: UUID)
    case splitTerminal(workspaceID: UUID, surfaceID: UUID, direction: CmuxSidebarSplitDirection)
    case splitBrowser(workspaceID: UUID, surfaceID: UUID, direction: CmuxSidebarSplitDirection, url: String?)
    case toggleSurfaceZoom(workspaceID: UUID, surfaceID: UUID)
    case openURL(String)
    /// Prompts natively when `title` is nil; an empty title clears the custom name.
    case renameWorkspace(workspaceID: UUID, title: String?)
    /// Prompts natively when `title` is nil; an empty title clears the custom name.
    case renameSurface(workspaceID: UUID, surfaceID: UUID, title: String?)
    /// Prompts natively when `title` is nil; a group name must remain nonempty.
    case renameWorkspaceGroup(groupID: UUID, title: String?)
    /// Creates a native group from existing workspaces or with a new anchor.
    case createWorkspaceGroup(name: String, workspaceIDs: [UUID])
    /// Applies a workspace pin state through the host's native model.
    case setWorkspacePinned(workspaceID: UUID, isPinned: Bool)
    /// Applies a user-selected importance marker without changing agent activity.
    case setWorkspaceImportance(workspaceID: UUID, importance: CmuxSidebarWorkspaceImportance)
    /// Applies the native group expansion state.
    case setWorkspaceGroupCollapsed(groupID: UUID, isCollapsed: Bool)
    /// Assigns a workspace to a group, or removes its assignment when the ID is nil.
    case moveWorkspaceToGroup(workspaceID: UUID, groupID: UUID?)
    /// Removes native grouping while retaining all member workspaces.
    case ungroupWorkspaceGroup(groupID: UUID)
    /// Confirms natively before deleting a group and closing its confirmed members.
    case deleteWorkspaceGroup(groupID: UUID)
    /// Marks the target workspace's notification state as read.
    case markWorkspaceRead(workspaceID: UUID)
    /// Marks the target workspace's notification state as unread.
    case markWorkspaceUnread(workspaceID: UUID)
    /// Clears the target workspace's latest notification.
    case clearWorkspaceNotifications(workspaceID: UUID)
    /// Applies the target workspace's notification mute state.
    case setWorkspaceMuted(workspaceID: UUID, isMuted: Bool)
    /// Sets or clears the native custom description; nil clears it.
    case setWorkspaceDescription(workspaceID: UUID, description: String?)
    /// Sets or clears the native custom color; nil restores the default.
    case setWorkspaceColor(workspaceID: UUID, colorHex: String?)
    /// Moves a workspace before another workspace, or to the end when nil.
    case moveWorkspace(workspaceID: UUID, beforeWorkspaceID: UUID?)

    /// Applies one deliberate metadata mutation to the exact native revision.
    case mutateWorkspaceContext(workspaceID: UUID, expectedRevision: UInt64, mutation: CmuxSidebarWorkspaceContextMutation)
    /// Persists an analyzed proposal without accepting its metadata.
    case storeWorkspaceContextProposal(workspaceID: UUID, expectedRevision: UInt64, proposal: CmuxSidebarWorkspaceContextProposal)
    /// Accepts explicitly selected fields from the exact retained proposal.
    case applyWorkspaceContextProposal(workspaceID: UUID, expectedRevision: UInt64, proposalID: UUID, tagIDs: [String], acceptTitle: Bool, acceptSummary: Bool)
    /// Reverses the latest context edit; its native revision remains monotonic.
    case undoWorkspaceContext(workspaceID: UUID, expectedRevision: UInt64)
    /// Binds a user-supplied identity only while the captured process generation still owns the surface.
    case bindAgentSession(workspaceID: UUID, surfaceID: UUID, toolID: String, sessionID: String, expectedProcessGeneration: UInt64)

    public var requiredScopes: Set<CmuxExtensionActionScope> {
        switch self {
        case .createWorkspace(_, let workingDirectory, _):
            return workingDirectory == nil ? [.createWorkspace] : [.createWorkspace, .createWorkspaceWithPath]
        case .selectWorkspace:
            return [.selectWorkspace]
        case .closeWorkspace:
            return [.closeWorkspace]
        case .selectNextWorkspace, .selectPreviousWorkspace:
            return [.navigateWorkspace]
        case .createTerminalSurface:
            return [.createSurface]
        case .createBrowserSurface(_, let url):
            return url == nil ? [.createSurface] : [.createSurface, .openURL]
        case .selectSurface:
            return [.selectSurface]
        case .selectNextSurface, .selectPreviousSurface:
            return [.navigateSurface]
        case .closeSurface:
            return [.closeSurface]
        case .splitTerminal:
            return [.splitSurface]
        case .splitBrowser(_, _, _, let url):
            return url == nil ? [.splitSurface] : [.splitSurface, .openURL]
        case .toggleSurfaceZoom:
            return [.zoomSurface]
        case .openURL:
            return [.openURL]
        case .renameWorkspace:
            return [.renameWorkspace]
        case .renameSurface:
            return [.renameSurface]
        case .renameWorkspaceGroup:
            return [.renameWorkspaceGroup]
        case .createWorkspaceGroup:
            return [.createWorkspaceGroup, .createWorkspace]
        case .setWorkspacePinned:
            return [.pinWorkspace]
        case .setWorkspaceImportance:
            return [.setWorkspaceImportance]
        case .setWorkspaceGroupCollapsed:
            return [.collapseWorkspaceGroup]
        case .moveWorkspaceToGroup:
            return [.moveWorkspaceToGroup]
        case .ungroupWorkspaceGroup:
            return [.ungroupWorkspaceGroup]
        case .deleteWorkspaceGroup:
            return [.deleteWorkspaceGroup, .closeWorkspace]
        case .markWorkspaceRead, .markWorkspaceUnread, .clearWorkspaceNotifications:
            return [.manageNotifications]
        case .setWorkspaceMuted:
            return [.muteWorkspace]
        case .setWorkspaceDescription:
            return [.editWorkspaceDescription]
        case .setWorkspaceColor:
            return [.colorWorkspace]
        case .moveWorkspace:
            return [.reorderWorkspace]
        case .mutateWorkspaceContext, .storeWorkspaceContextProposal:
            return [.editWorkspaceContext]
        case .applyWorkspaceContextProposal(_, _, _, _, let acceptTitle, _):
            return acceptTitle ? [.editWorkspaceContext, .renameWorkspace] : [.editWorkspaceContext]
        case .undoWorkspaceContext:
            return [.editWorkspaceContext, .renameWorkspace]
        case .bindAgentSession:
            return [.bindAgentSession]
        }
    }
}
