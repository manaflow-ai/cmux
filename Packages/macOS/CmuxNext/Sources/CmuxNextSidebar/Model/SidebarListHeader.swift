/// A header Projects and Recents (`sidebar.groupBy` = recents) draws over its two lists.
public nonisolated enum SidebarListHeader: String, Hashable, Sendable {
    /// Over every computer's groups.
    case projects
    /// Over every workspace in no group, the newest activity first.
    case recents
}
