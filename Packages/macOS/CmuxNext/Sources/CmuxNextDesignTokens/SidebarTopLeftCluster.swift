/// `sidebar.topLeftCluster`: how the sidebar's top-left corner group draws (the + New Workspace button,
/// the header, the start of the workspace list and the first horizontal tab). Leo 2026-11-05: "There's
/// just this extremely awful corner area where it's like, okay, you have this plus symbol, and then you
/// have the divider, and then you have like the workspaces, and then you have the top horizontal tab",
/// and "that search button, that like magnifying glass, it isn't aligned. And the new workspace, like
/// those two things, like they're just not aligned."
///
/// Every look but `standard` puts the + on the trailing column the footer's Search uses (one center x)
/// at Search's glyph size and box (one baseline inside the box). Compact density always draws
/// `standard` (Lawrence likes the ultra compact sidebar as it is); see ``effective(compact:)``.
public nonisolated enum SidebarTopLeftCluster: String, Hashable, Sendable, CaseIterable {
    /// Today's corner, unchanged (the default): the + at the header's trailing inset.
    case standard
    /// Only the alignment fix: the + on Search's column, at Search's glyph size.
    case aligned
    /// One header row on one grid: the traffic lights' spacing, then Search and the + on the trailing
    /// slots (Search one slot pitch before the +, as a hovered row's ⋮ sits before its ×).
    case headerRow
    /// The + becomes a full-width "New Workspace" row at the top of the list, on the rows' lead and text
    /// columns; the header keeps only the window's controls.
    case listRow
    /// The + moves into the first tab strip's leading slot, right after the sidebar's edge, so the
    /// corner reads as one row: sidebar, +, tabs.
    case tabLead

    /// The look that draws at a density: compact keeps `standard` whatever the setting says.
    public func effective(compact: Bool) -> SidebarTopLeftCluster { compact ? .standard : self }

    /// Whether the + sits on the footer Search's column and glyph size.
    public var alignsWithSearch: Bool { self != .standard }
}
