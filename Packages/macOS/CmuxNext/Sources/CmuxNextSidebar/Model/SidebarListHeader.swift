/// A header Projects and Recents (`sidebar.groupBy` = recents) draws over its two lists. One list has no heading: its
/// first row sits right under the pinned rows (https://github.com/manaflow-ai/cmux/issues/42373).
public nonisolated enum SidebarListHeader: String, Hashable, Sendable {
    /// Over every computer's groups.
    case projects
    /// Over every workspace in no group, the newest activity first.
    case recents
}
