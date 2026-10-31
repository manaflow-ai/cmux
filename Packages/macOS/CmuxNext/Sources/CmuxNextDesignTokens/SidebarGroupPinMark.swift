/// `sidebar.groupPinMark`: how a workspace pinned inside its group shows that it is pinned at rest
/// (pinning-DESIGN.md: before it, the pin showed only on an expanded row's hover). Three looks to
/// pick from (Aziz 2026-10-30: "a better indicator for pinned items under a workspace group").
public nonisolated enum SidebarGroupPinMark: String, Hashable, Sendable, CaseIterable {
    /// No mark at rest: the pin shows only on an expanded row's hover, as before.
    case off
    /// A small filled pin in the row's trailing marks, in the tertiary ink.
    case trailing
    /// A small filled pin before the name, in the group's color.
    case leading
    /// The pinned members sit on a faint wash of the group's color, a shelf at the top of the group.
    case shelf
}
