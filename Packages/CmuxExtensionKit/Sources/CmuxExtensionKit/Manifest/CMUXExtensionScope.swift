import Foundation

public enum CMUXExtensionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceList
    case workspaceMetadata
    case surfaceMetadata
    case workspacePaths
    case notifications
    case networkPorts
    case pullRequests
}

public enum CMUXExtensionActionScope: String, Codable, CaseIterable, Equatable, Sendable {
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
}
