/// Where archived workspaces appear in the sidebar. Membership is unchanged.
public nonisolated enum SidebarArchivedPlacement: String, Hashable, Sendable, CaseIterable {
    /// Fold archived members at the end of their original group; loose rows use Archive.
    case withinGroups
    /// Collect every archived workspace in the sidebar's Archive section.
    case archiveSection
}
