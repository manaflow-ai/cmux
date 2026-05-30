import Foundation

public enum CMUXSplitDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum CMUXSidebarAction: Codable, Equatable, Sendable {
    case createWorkspace(title: String?, workingDirectory: String?, select: Bool)
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case selectNextWorkspace
    case selectPreviousWorkspace
    case createTerminalSurface(workspaceID: UUID?, initialInput: String?)
    case createBrowserSurface(workspaceID: UUID?, url: String?)
    case selectSurface(workspaceID: UUID, surfaceID: UUID)
    case selectNextSurface
    case selectPreviousSurface
    case closeSurface(workspaceID: UUID, surfaceID: UUID)
    case splitTerminal(workspaceID: UUID, surfaceID: UUID, direction: CMUXSplitDirection)
    case splitBrowser(workspaceID: UUID, surfaceID: UUID, direction: CMUXSplitDirection, url: String?)
    case toggleSurfaceZoom(workspaceID: UUID, surfaceID: UUID)
    case openURL(String)

    public var requiredScope: CMUXExtensionActionScope {
        switch self {
        case .createWorkspace:
            return .createWorkspace
        case .selectWorkspace:
            return .selectWorkspace
        case .closeWorkspace:
            return .closeWorkspace
        case .selectNextWorkspace, .selectPreviousWorkspace:
            return .navigateWorkspace
        case .createTerminalSurface, .createBrowserSurface:
            return .createSurface
        case .selectSurface:
            return .selectSurface
        case .selectNextSurface, .selectPreviousSurface:
            return .navigateSurface
        case .closeSurface:
            return .closeSurface
        case .splitTerminal, .splitBrowser:
            return .splitSurface
        case .toggleSurfaceZoom:
            return .zoomSurface
        case .openURL:
            return .openURL
        }
    }
}
