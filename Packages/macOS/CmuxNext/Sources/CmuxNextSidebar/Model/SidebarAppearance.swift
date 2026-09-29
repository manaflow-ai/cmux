import Foundation

/// User-selectable colors for groups, swatches, and tints. These are content
/// colors picked by the user, never UI accents.
public nonisolated enum SidebarColor: String, CaseIterable, Sendable, Codable {
    case gray, red, orange, yellow, green, mint, cyan, blue, purple, pink
}

/// Workspace icon: an SF Symbol (optionally tinted) or a color swatch.
public nonisolated enum WorkspaceIcon: Hashable, Sendable {
    case symbol(String, tint: SidebarColor? = nil)
    case swatch(SidebarColor)
}

/// Agent activity shown as a small indicator on the row.
public nonisolated enum AgentActivity: Hashable, Sendable {
    case idle
    case running
    case needsInput
    case error
}

/// Unread state for the badge.
public nonisolated enum UnreadState: Hashable, Sendable {
    case none
    case dot
    case count(Int)

    public var isUnread: Bool {
        switch self {
        case .none: false
        case .dot: true
        case let .count(n): n > 0
        }
    }
}

/// How the sidebar occupies the window.
public nonisolated enum SidebarPresentation: Hashable, Sendable {
    case expanded
    case iconsOnly
    case hidden
}
