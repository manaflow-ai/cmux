import Foundation

public enum CmuxSidebarSplitDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

@_spi(CmuxHostTransport)
public enum CmuxSidebarAction: Codable, Equatable, Sendable {
    case selectCreationContext(String)
    case reorderCreationContext(id: String, toIndex: Int)
    case moveWorkspacesToCreationContext(workspaceIDs: [UUID], contextID: String)
    case addSSHMachine(destination: String, select: Bool)
    case attachRemoteCmuxTUI(contextID: String, sessionName: String, workspaceID: UUID?)
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

    public var requiredScopes: Set<CmuxExtensionActionScope> {
        switch self {
        case .selectCreationContext:
            return [.selectCreationContext]
        case .reorderCreationContext, .moveWorkspacesToCreationContext:
            return [.reorderCreationContexts]
        case .addSSHMachine:
            return [.addSSHMachine]
        case .attachRemoteCmuxTUI:
            return [.attachRemoteSession]
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
        }
    }
}
