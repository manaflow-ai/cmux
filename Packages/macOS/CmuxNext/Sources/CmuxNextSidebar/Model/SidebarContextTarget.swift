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
    /// A dot in the profile bar.
    case profile(ProfileKey)
    /// An item of a sticky section.
    case layoutItem(LayoutItemID)
    /// The header of a titled sticky section.
    case layoutSection(LayoutSectionID)
}
