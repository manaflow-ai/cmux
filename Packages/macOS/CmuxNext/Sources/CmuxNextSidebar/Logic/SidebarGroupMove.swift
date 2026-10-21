/// Where a group ordering verb sends a workspace group among the rows of its
/// sidebar section (Move Group to Top, Up, Down, to Bottom).
///
/// A section lists loose workspace rows and groups in one order, so a step
/// moves past the next row of either kind, as a drag would.
///
/// ```swift
/// if let index = SidebarEdits.groupIndex(group, .top, in: model.sections) {
///     bridge.handle(.reorderGroup(group, index: index))
/// }
/// ```
public nonisolated enum SidebarGroupMove: Sendable, Hashable, CaseIterable {
    /// Above every row of the section.
    case top
    /// Below every row of the section.
    case bottom
    /// Above the row right above the group.
    case up
    /// Below the row right below the group.
    case down
}
