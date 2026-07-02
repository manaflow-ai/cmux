import Foundation

public enum CmuxExtensionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceList
    case workspaceMetadata
    case surfaceMetadata
    case workspacePaths
    case notifications
    case networkPorts
    case pullRequests
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
    /// Run workspace commands already defined by the user in cmux.json.
    ///
    /// Introduced in API ``CmuxExtensionAPIVersion/sidebarV2_1``. Manifests requesting
    /// this scope must declare `minimumAPIVersion` 2.1 or newer; `validateSidebarManifest`
    /// rejects a lower declaration.
    case runWorkspaceCommand
}
