import CmuxNextDesign

/// Group by Folder and Group by Status on the model (`SidebarGrouping`).
extension SidebarModel {
    /// Group by Folder: loose rows sit under folder headers.
    public var groupsByFolder: Bool { grouping.groupsByFolder }
    /// Group by Status (Debug `sidebar.groupByStatus`): rows sit under the Priority view's states.
    public var groupsByStatus: Bool { grouping.byStatus }

    /// Follows the Debug toggle (`SidebarView` reads it with the other list settings). Off forgets the held row and
    /// the folds.
    func groupByStatus(_ on: Bool) {
        guard on != grouping.byStatus else { return }
        grouping.setByStatus(on)
    }

    /// A Group by Status header's click: fold or unfold its rows. Needs you never folds.
    public func toggleStatusSection(_ section: SidebarStatusSection) {
        guard section.collapses else { return }
        if grouping.collapsed.remove(section) == nil { grouping.collapsed.insert(section) }
    }

    /// The grouping the list lays out: a held row that is no longer the active row moves to its own section, and
    /// keeps no hold for when it is active again.
    func settledGrouping() -> SidebarGrouping {
        if let held = grouping.held, held.row != activeWorkspaceID { grouping.held = nil }
        return grouping
    }

    /// Whether `new` (the patched `old`) changes which rows the list draws: the base rules (`movesRows(from:to:groupsByFolder:)`:
    /// a folder, the Done fold, the row limit), and with Group by Status a row whose status
    /// section changes. The active row keeps its section while it stays active (`SidebarGrouping.held`): a patch, not a move.
    func movesRows(from old: SidebarWorkspace, to new: SidebarWorkspace) -> Bool {
        if groupsByStatus {
            let before = settledGrouping().section(old)
            if before != SidebarStatusSection(new) {
                guard new.id == activeWorkspaceID else { return true }
                grouping.held = (new.id, before)
            }
        }
        return Self.movesRows(from: old, to: new, groupsByFolder: groupsByFolder)
    }
}
