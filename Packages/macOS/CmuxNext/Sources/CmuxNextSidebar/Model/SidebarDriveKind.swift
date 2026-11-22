import Foundation

/// What an agent drives in a workspace: the Mac's screen (Computer Use) or a browser tab.
public nonisolated enum SidebarDriveKind: String, Hashable, Sendable, CaseIterable {
    /// Computer Use: the agent clicks and types in the person's apps.
    case screen
    /// The agent drives a browser tab.
    case browser

    /// The SF Symbol the indicators draw for it.
    public var symbol: String {
        switch self {
        case .screen: "display"
        case .browser: "globe"
        }
    }
}
