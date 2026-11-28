import Foundation

extension SidebarModel {
    /// A content change that changes which rows the list draws: a folder (Group by Folder), Done (the Done fold),
    /// needing you past the row limit (it keeps a row out of "Show N more"), or, with `settles`
    /// (`sidebar.settleFinished`), a chat that settles or rises back (the "Settled (N)" fold), or, with
    /// `shelves` (`sidebar.workingShelf`), a chat that goes on or comes off the "Working (N)" shelf.
    static func movesRows(from old: SidebarWorkspace, to new: SidebarWorkspace, groupsByFolder: Bool, settles: Bool = false,
                          shelves: Bool = false) -> Bool {
        if groupsByFolder && old.folder != new.folder { return true }
        if (old.taskStatus == .done) != (new.taskStatus == .done) { return true }
        if shelves && shelfMoves(from: old, to: new) { return true }
        if settles && settleMoves(from: old, to: new) { return true }
        return SidebarTunables.rowLimit > 0 && (old.agentChip == .needsYou) != (new.agentChip == .needsYou)
    }
}
