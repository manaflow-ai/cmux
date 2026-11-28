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
    case placeholder
}
