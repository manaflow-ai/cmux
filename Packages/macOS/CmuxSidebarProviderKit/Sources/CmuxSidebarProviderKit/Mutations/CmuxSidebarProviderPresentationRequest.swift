import Foundation

/// Presentation command a provider can request from the CMUX sidebar host.
public enum CmuxSidebarProviderPresentationRequest: Codable, Equatable, Sendable {
    /// Open the workspace popover on a preferred tab.
    case openWorkspacePopover(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    /// Open a detached workspace window on a preferred tab.
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    /// Ask CMUX to open a URL.
    case openURL(String)
}
