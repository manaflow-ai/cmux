import Foundation

/// The nine group colors shared with tab groups (Chrome's set). They are
/// user content, rendered as muted tints tuned for the gray UI; the no-blue
/// rule applies to app chrome, not to a color the user picked.
public nonisolated enum SidebarColor: String, CaseIterable, Sendable, Codable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange
}

/// Workspace icon: an SF Symbol (optionally tinted) or a color swatch.
public nonisolated enum WorkspaceIcon: Hashable, Sendable {
    case symbol(String, tint: SidebarColor? = nil)
    case swatch(SidebarColor)
}

/// How the sidebar occupies the window.
public nonisolated enum SidebarPresentation: Hashable, Sendable {
    case expanded
    case iconsOnly
    case hidden
}
