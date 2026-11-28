import Foundation

/// Where a workspace row's content comes from (snapshot-first launch,
/// plans/cmux-next/sidebar-sections.md): rows draw at once from what the
/// app saved last time, then update in place when the daemon answers.
public nonisolated enum SidebarRowState: Hashable, Sendable {
    /// Daemon data from this connection: everything the row shows is current.
    case live
    /// Saved or provisional data (the app's sidebar snapshot, or the
    /// daemon's launch snapshot before the live tree): the title and icon
    /// as last known, without live status, activity or unread counts.
    case stale
    /// A row the sidebar knows nothing about yet (a machine still
    /// connecting with no saved rows): a static tonal bar, never interactive.
    /// With a title (a connecting SSH machine's pending row, cx-gaq9) it draws
    /// the title and second line instead of the bar, still never interactive.
    case placeholder
    /// A workspace this app is creating, from the press until the daemon
    /// lists it: drawn exactly as its live row will be (its final title,
    /// folder and look, no bar, no dim), so the row never changes look when
    /// the daemon replies. Like a placeholder it is never interactive: the
    /// daemon does not know the workspace yet.
    case creating

    /// True for a row that names no daemon workspace yet (a placeholder, or a
    /// workspace still being created): no selection, menu, drag or save.
    public var isPending: Bool { self == .placeholder || self == .creating }
}
