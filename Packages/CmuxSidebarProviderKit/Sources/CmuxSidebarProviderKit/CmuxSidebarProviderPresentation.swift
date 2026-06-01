import Foundation

/// Visual presentation style used to render provider output in CMUX's sidebar.
public enum CmuxSidebarProviderPresentation: String, Codable, Equatable, Sendable {
    /// Standard tree/list sidebar layout.
    case tree
    /// Browser-stack layout with stable required sections.
    case browserStack = "browser-stack"
}

/// Tabs available when CMUX opens a workspace popover for a provider row.
public enum CmuxSidebarProviderWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    /// Notes tab.
    case notes
    /// Browser previews tab.
    case browser
    /// Pull request details tab.
    case pullRequest
}
