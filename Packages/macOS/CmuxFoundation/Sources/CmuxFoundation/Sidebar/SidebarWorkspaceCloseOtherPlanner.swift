public import Foundation

/// Pure policy resolving the workspace ids closed by the sidebar's "Close Other
/// Workspaces" action, honoring an active workspace tag filter so the action never
/// destroys rows the filter hides. Holds no state and touches no UI.
///
/// "Close Other Workspaces" keeps an explicit set of ids — the right-clicked row and
/// any multi-selection, all of which are *visible* rows — and closes the rest.
/// Resolving "the rest" as the complement against the full `tabManager.tabs` list is
/// safe only when every workspace is visible: under a tag filter the rendered rows
/// are a subset, so a full-list complement would close hidden, non-matching
/// workspaces the user cannot even see — the same data-loss hazard that
/// `SidebarWorkspacePositionRelativeActionGate` refuses for Close Above/Below. While
/// a filter is active the action is therefore refused (the context-menu item is
/// disabled and this planner yields no ids); the user clears the filter to close by
/// set.
public struct SidebarWorkspaceCloseOtherPlanner {
    /// Creates the planner. The policy is stateless, so call sites construct a fresh
    /// value at each use rather than sharing one.
    public init() {}

    /// The workspace ids "Close Other Workspaces" closes, in full sidebar order.
    ///
    /// - Parameters:
    ///   - fullOrderWorkspaceIds: Every workspace id in full sidebar order.
    ///   - keptWorkspaceIds: The ids the action keeps open (never closed) — the
    ///     right-clicked row and any multi-selection.
    ///   - activeWorkspaceTagFilter: The tag currently filtering the sidebar rows, or
    ///     `nil` when every workspace is shown.
    /// - Returns: The non-kept ids to close when no filter hides rows; an empty array
    ///   while a tag filter is active, so hidden workspaces are never closed.
    public func workspaceIdsToClose(
        fullOrderWorkspaceIds: [UUID],
        keptWorkspaceIds: Set<UUID>,
        activeWorkspaceTagFilter: String?
    ) -> [UUID] {
        // A tag filter renders only matching rows, so the full-list complement would
        // reach hidden, non-matching workspaces. Refuse while filtered (the
        // context-menu item is likewise disabled) so no hidden workspace is ever
        // closed; the user clears the filter to close by set.
        guard activeWorkspaceTagFilter == nil else { return [] }
        return fullOrderWorkspaceIds.filter { !keptWorkspaceIds.contains($0) }
    }
}
