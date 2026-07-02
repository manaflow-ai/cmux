/// Pure policy gating *relative* sidebar workspace reorders (drag, and the
/// context-menu / accessibility "Move Up" / "Move Down" actions) against the
/// active workspace tag filter. Holds no state and touches no UI.
///
/// Relative reorders operate in full `tabManager.tabs` coordinates: a drag plans
/// an insertion index and the ±1 actions step `index ± 1`, both committed against
/// the full workspace order. A tag filter renders only the matching rows, so
/// hidden rows make the filtered row order diverge from the full order — a ±1 step
/// can jump across a hidden neighbor and leave the *visible* order unchanged (a
/// confusing no-op) or land the workspace in a hidden slot. Reordering is therefore
/// unsupported while a tag filter is active; the user clears the filter to reorder.
///
/// The gate is deliberately scoped to relative reorders. Absolute moves ("Move to
/// Top", full index 0) stay unambiguous under a filter, and keyboard / socket / CLI
/// reorders that already operate purely on full-list ids do not render filtered
/// rows, so none of those consult this gate.
public struct SidebarWorkspaceReorderGatePolicy {
    public init() {}

    /// Whether a relative reorder (drag / Move Up / Move Down) may be committed.
    ///
    /// - Parameter activeWorkspaceTagFilter: The tag currently filtering the sidebar
    ///   rows, or `nil` when every workspace is shown.
    /// - Returns: `true` only when no tag filter is hiding rows.
    public func allowsRelativeReorder(activeWorkspaceTagFilter: String?) -> Bool {
        activeWorkspaceTagFilter == nil
    }
}
