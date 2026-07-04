/// Pure policy gating *position-relative* sidebar workspace actions — drag reorder,
/// the "Move Up"/"Move Down" actions, and the destructive "Close Workspaces
/// Above"/"Close Workspaces Below" menu items — against the active workspace tag
/// filter. Holds no state and touches no UI.
///
/// These actions derive their meaning from a workspace's neighbors in the full
/// `tabManager.tabs` order: a drag plans an insertion index, the ±1 moves step
/// `index ± 1`, and close-above/below slice the list around the row's full-list
/// index. A tag filter renders only the matching rows, so hidden rows make the
/// filtered row order diverge from the full order. Under that divergence a move or
/// drag becomes a visible no-op (or lands in a hidden slot) and — worse — a
/// close-above/below can destroy workspaces the user cannot even see. All of them
/// are therefore refused while a tag filter is active; the user clears the filter
/// to act.
///
/// The gate is scoped to position-relative actions. The genuinely set-based actions
/// ("Close" the selection, move-to-window) and absolute moves ("Move to Top", full
/// index 0) operate on explicit workspace ids without positional ambiguity, so they
/// do not consult this gate. "Close Other Workspaces" is *not* one of those safe
/// actions: it keeps the visible selection and closes the complement against the full
/// list, so under a filter it would reach hidden rows — `SidebarWorkspaceCloseOtherPlanner`
/// refuses it while filtered (and its menu item is disabled) instead of routing
/// through this position gate. Keyboard / socket / CLI / command-palette paths operate
/// on full-list ids without rendering filtered rows, so none of those consult this gate.
public struct SidebarWorkspacePositionRelativeActionGate {
    /// Creates the gate. The policy is stateless, so call sites construct a fresh
    /// value at each use rather than sharing one.
    public init() {}

    /// Whether a position-relative action (drag / Move Up / Move Down / Close
    /// Above / Close Below) may run.
    ///
    /// - Parameter activeWorkspaceTagFilter: The tag currently filtering the sidebar
    ///   rows, or `nil` when every workspace is shown.
    /// - Returns: `true` only when no tag filter is hiding rows.
    public func allows(activeWorkspaceTagFilter: String?) -> Bool {
        activeWorkspaceTagFilter == nil
    }
}
