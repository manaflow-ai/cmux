public import CmuxNextDesign
import Foundation

/// Workspace icon: an SF Symbol (optionally tinted) or a color swatch.
public nonisolated enum WorkspaceIcon: Hashable, Sendable {
    case symbol(String, tint: GroupColor? = nil)
    case swatch(GroupColor)
}

/// How the sidebar occupies the window: fully shown at the user's width,
/// or fully hidden (zero width, content reaches the window edge). There is
/// no intermediate state.
public nonisolated enum SidebarPresentation: Hashable, Sendable {
    case shown
    case hidden
}
