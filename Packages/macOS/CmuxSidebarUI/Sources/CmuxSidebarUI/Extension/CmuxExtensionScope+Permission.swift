public import CmuxExtensionKit
import Foundation

extension CmuxExtensionScope {
    /// Human-readable name for a read scope, shown as the title of a permission
    /// row in the extension details popover.
    ///
    /// Localized with `bundle: .main` so the keys resolve against the app
    /// bundle's catalog (including Japanese) rather than this package's bundle,
    /// matching the original app-side `String(localized:)` lookup.
    @_spi(CmuxHostTransport)
    public var displayName: String {
        switch self {
        case .workspaceList:
            return String(localized: "sidebar.extensions.scope.workspaceList", defaultValue: "Workspace list", bundle: .main)
        case .workspaceMetadata:
            return String(localized: "sidebar.extensions.scope.workspaceMetadata", defaultValue: "Workspace metadata", bundle: .main)
        case .surfaceMetadata:
            return String(localized: "sidebar.extensions.scope.surfaceMetadata", defaultValue: "Surface metadata", bundle: .main)
        case .workspacePaths:
            return String(localized: "sidebar.extensions.scope.workspacePaths", defaultValue: "Workspace paths", bundle: .main)
        case .notifications:
            return String(localized: "sidebar.extensions.scope.notifications", defaultValue: "Notifications", bundle: .main)
        case .networkPorts:
            return String(localized: "sidebar.extensions.scope.networkPorts", defaultValue: "Network ports", bundle: .main)
        case .pullRequests:
            return String(localized: "sidebar.extensions.scope.pullRequests", defaultValue: "Pull requests", bundle: .main)
        }
    }

    /// Full-sentence description of what a read scope grants, shown as the detail
    /// text of a permission row in the extension details popover.
    ///
    /// Localized with `bundle: .main` so the keys resolve against the app
    /// bundle's catalog (including Japanese) rather than this package's bundle,
    /// matching the original app-side `String(localized:)` lookup.
    @_spi(CmuxHostTransport)
    public var permissionDescription: String {
        switch self {
        case .workspaceList:
            return String(localized: "sidebar.extensions.permission.workspaceList.detail", defaultValue: "Read workspace IDs and names", bundle: .main)
        case .workspaceMetadata:
            return String(localized: "sidebar.extensions.permission.workspaceMetadata.detail", defaultValue: "Read workspace names, branches, unread counts, and selection", bundle: .main)
        case .surfaceMetadata:
            return String(localized: "sidebar.extensions.permission.surfaceMetadata.detail", defaultValue: "Read surfaces nested inside each workspace", bundle: .main)
        case .workspacePaths:
            return String(localized: "sidebar.extensions.permission.workspacePaths.detail", defaultValue: "Read local workspace and project paths", bundle: .main)
        case .notifications:
            return String(localized: "sidebar.extensions.permission.notifications.detail", defaultValue: "Read latest workspace notifications", bundle: .main)
        case .networkPorts:
            return String(localized: "sidebar.extensions.permission.networkPorts.detail", defaultValue: "Read listening ports for each workspace", bundle: .main)
        case .pullRequests:
            return String(localized: "sidebar.extensions.permission.pullRequests.detail", defaultValue: "Read pull request links associated with workspaces", bundle: .main)
        }
    }
}
