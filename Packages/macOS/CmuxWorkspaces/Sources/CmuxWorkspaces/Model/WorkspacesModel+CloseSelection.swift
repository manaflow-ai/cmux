public import Foundation

// Selection hand-off for the workspace close path.
extension WorkspacesModel {
    /// The workspace that takes selection after the workspace previously at
    /// `closedIndex` was removed from `tabs`.
    ///
    /// Keeps the user's focused *row position* stable where possible: if a
    /// workspace still occupies the closed workspace's slot, that one is
    /// focused (it moved up into the slot); otherwise the closed workspace was
    /// last, so focus falls back to the new last workspace.
    ///
    /// The slot's occupant is resolved to a workspace the sidebar actually
    /// renders: `tabs` stores every workspace, but a non-anchor member of a
    /// *collapsed* group has no row of its own, and selecting one would fire
    /// `expandWorkspaceGroupForSelectionIfNeeded` and unfold a group the user
    /// deliberately collapsed. Such a member resolves to its group's anchor —
    /// the row the sidebar draws for it — matching how
    /// `toggleWorkspaceGroupCollapsed` moves focus to the anchor when a
    /// collapse would hide the selected member.
    ///
    /// Callers must have already removed the closed workspace from `tabs`.
    /// Returns nil when no workspace remains.
    public func selectionTargetAfterClose(closedIndex: Int) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let newIndex = min(closedIndex, max(0, tabs.count - 1))
        let candidate = tabs[newIndex]
        guard let groupId = candidate.groupId,
              let group = workspaceGroups.first(where: { $0.id == groupId }),
              group.isCollapsed else {
            return candidate.id
        }
        return group.anchorWorkspaceId
    }
}
