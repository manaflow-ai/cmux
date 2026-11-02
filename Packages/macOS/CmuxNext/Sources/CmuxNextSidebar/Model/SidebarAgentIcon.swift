import Foundation

/// A custom harness's own icon on a workspace row (user 12922), drawn where an agent's brand mark
/// goes (`SidebarWorkspace.agentBrand`): a full-color image (an emoji, a PNG or SVG, a monogram),
/// drawn as is, or an SF Symbol, tinted like the marks.
public nonisolated enum SidebarAgentIcon: Hashable, Sendable {
    /// Drawn as is.
    case image(SidebarFavicon)
    /// An SF Symbol name, tinted like a brand mark.
    case symbol(String)
}
