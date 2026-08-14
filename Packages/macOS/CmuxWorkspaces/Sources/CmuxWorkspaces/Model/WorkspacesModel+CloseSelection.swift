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
    /// Callers must have already removed the closed workspace from `tabs`.
    /// Returns nil when no workspace remains.
    public func selectionTargetAfterClose(closedIndex: Int) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let newIndex = min(closedIndex, max(0, tabs.count - 1))
        return tabs[newIndex].id
    }
}
