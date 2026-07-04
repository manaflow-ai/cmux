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
    /// rejects a lower declaration, and `CmuxExtensionManifest.init` derives the version
    /// from the requested scopes so authors get it automatically.
    case runWorkspaceCommand
}

extension CmuxExtensionActionScope {
    /// The earliest sidebar API version that includes this action scope.
    ///
    /// The switch is deliberately exhaustive (no `default`) so that adding a new scope
    /// forces a decision about which API version introduces it.
    @_spi(CmuxHostTransport)
    public var minimumAPIVersion: CmuxExtensionAPIVersion {
        switch self {
        case .runWorkspaceCommand:
            return .sidebarV2_1
        case .createWorkspace, .selectWorkspace, .closeWorkspace, .createSurface,
             .selectSurface, .closeSurface, .splitSurface, .zoomSurface,
             .navigateWorkspace, .navigateSurface, .openURL, .createWorkspaceWithPath:
            return .sidebarV2
        }
    }
}
