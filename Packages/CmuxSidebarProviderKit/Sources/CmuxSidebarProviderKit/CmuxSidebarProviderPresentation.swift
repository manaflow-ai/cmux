import Foundation

public enum CmuxSidebarProviderPresentation: String, Codable, Equatable, Sendable {
    case tree
    case browserStack = "browser-stack"
}

public enum CmuxSidebarProviderWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    case notes
    case browser
    case pullRequest
}
