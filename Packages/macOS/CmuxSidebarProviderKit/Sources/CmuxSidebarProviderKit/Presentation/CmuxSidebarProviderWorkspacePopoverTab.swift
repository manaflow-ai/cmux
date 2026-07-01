import Foundation

/// Tabs available when CMUX opens a workspace popover for a provider row.
public enum CmuxSidebarProviderWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    /// Notes tab.
    case notes
    /// Browser previews tab.
    case browser
    /// Pull request details tab.
    case pullRequest
}
