public import CmuxExtensionKit
import Foundation

extension CmuxExtensionActionScope {
    /// Human-readable name for an action scope, shown as the title of a
    /// permission row in the extension details popover.
    ///
    /// Localized with `bundle: .main` so the keys resolve against the app
    /// bundle's catalog (including Japanese) rather than this package's bundle,
    /// matching the original app-side `String(localized:)` lookup.
    @_spi(CmuxHostTransport)
    public var displayName: String {
        switch self {
        case .createWorkspace:
            return String(localized: "sidebar.extensions.actionScope.createWorkspace", defaultValue: "Create workspaces", bundle: .main)
        case .selectWorkspace:
            return String(localized: "sidebar.extensions.actionScope.selectWorkspace", defaultValue: "Select workspaces", bundle: .main)
        case .closeWorkspace:
            return String(localized: "sidebar.extensions.actionScope.closeWorkspace", defaultValue: "Close workspaces", bundle: .main)
        case .createSurface:
            return String(localized: "sidebar.extensions.actionScope.createSurface", defaultValue: "Create surfaces", bundle: .main)
        case .selectSurface:
            return String(localized: "sidebar.extensions.actionScope.selectSurface", defaultValue: "Select surfaces", bundle: .main)
        case .closeSurface:
            return String(localized: "sidebar.extensions.actionScope.closeSurface", defaultValue: "Close surfaces", bundle: .main)
        case .splitSurface:
            return String(localized: "sidebar.extensions.actionScope.splitSurface", defaultValue: "Split surfaces", bundle: .main)
        case .zoomSurface:
            return String(localized: "sidebar.extensions.actionScope.zoomSurface", defaultValue: "Zoom surfaces", bundle: .main)
        case .navigateWorkspace:
            return String(localized: "sidebar.extensions.actionScope.navigateWorkspace", defaultValue: "Navigate workspaces", bundle: .main)
        case .navigateSurface:
            return String(localized: "sidebar.extensions.actionScope.navigateSurface", defaultValue: "Navigate surfaces", bundle: .main)
        case .openURL:
            return String(localized: "sidebar.extensions.actionScope.openURL", defaultValue: "Open URLs", bundle: .main)
        case .createWorkspaceWithPath:
            return String(localized: "sidebar.extensions.actionScope.createWorkspaceWithPath", defaultValue: "Create workspaces with paths", bundle: .main)
        }
    }

    /// Full-sentence description of what an action scope grants, shown as the
    /// detail text of a permission row in the extension details popover.
    ///
    /// Localized with `bundle: .main` so the keys resolve against the app
    /// bundle's catalog (including Japanese) rather than this package's bundle,
    /// matching the original app-side `String(localized:)` lookup.
    @_spi(CmuxHostTransport)
    public var permissionDescription: String {
        switch self {
        case .createWorkspace:
            return String(localized: "sidebar.extensions.permission.createWorkspace.detail", defaultValue: "Create workspaces", bundle: .main)
        case .selectWorkspace:
            return String(localized: "sidebar.extensions.permission.selectWorkspace.detail", defaultValue: "Select a workspace when you click in the extension", bundle: .main)
        case .closeWorkspace:
            return String(localized: "sidebar.extensions.permission.closeWorkspace.detail", defaultValue: "Close workspaces from the extension", bundle: .main)
        case .createSurface:
            return String(localized: "sidebar.extensions.permission.createSurface.detail", defaultValue: "Create terminal and browser surfaces", bundle: .main)
        case .selectSurface:
            return String(localized: "sidebar.extensions.permission.selectSurface.detail", defaultValue: "Select surfaces inside a workspace", bundle: .main)
        case .closeSurface:
            return String(localized: "sidebar.extensions.permission.closeSurface.detail", defaultValue: "Close surfaces inside a workspace", bundle: .main)
        case .splitSurface:
            return String(localized: "sidebar.extensions.permission.splitSurface.detail", defaultValue: "Create split surfaces", bundle: .main)
        case .zoomSurface:
            return String(localized: "sidebar.extensions.permission.zoomSurface.detail", defaultValue: "Toggle surface zoom", bundle: .main)
        case .navigateWorkspace:
            return String(localized: "sidebar.extensions.permission.navigateWorkspace.detail", defaultValue: "Navigate between workspaces", bundle: .main)
        case .navigateSurface:
            return String(localized: "sidebar.extensions.permission.navigateSurface.detail", defaultValue: "Navigate between surfaces", bundle: .main)
        case .openURL:
            return String(localized: "sidebar.extensions.permission.openURL.detail", defaultValue: "Open links from the extension", bundle: .main)
        case .createWorkspaceWithPath:
            return String(localized: "sidebar.extensions.permission.createWorkspaceWithPath.detail", defaultValue: "Create workspaces for specific local folders", bundle: .main)
        }
    }
}
