import Foundation

/// What a right-click in the sidebar targets. The App maps this to an ordered
/// list of action IDs from the action registry and returns the menu; the
/// sidebar never builds menu items itself.
public nonisolated enum SidebarContextTarget: Hashable, Sendable {
    /// The clicked row, or the whole selection when the row is part of it,
    /// in visual order.
    case workspaces([WorkspaceID])
    case group(GroupID)
    case section(SectionID)
    /// Empty space below or between sections.
    case background
    /// The + button's right-click and its chooser: only the rows that make something (New Workspace, New Browser
    /// Workspace, Open Folder…), never the sidebar's view toggles. Leo 2026-11-22 (ask-890db939a2): "we want to hide?
    /// we want to do something? pick a fucking option."
    case newButton
    /// Empty space in the bottom band (cx-wab7m): Show for each piece hidden from it.
    case footer
    /// The Now Playing card at the bottom (u2437): its hide rows and Play/Pause.
    case nowPlaying
    /// A dot in the profile bar.
    case profile(ProfileKey)
    /// An item of a pinned section.
    case layoutItem(LayoutItemID)
    /// The header of a titled pinned section.
    case layoutSection(LayoutSectionID)
    /// A row of the Priority view: its chat's session id.
    case priorityChat(String)
}
