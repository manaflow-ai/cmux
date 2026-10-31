import Foundation

extension SidebarModel {
    /// A content change that changes which rows the list draws: a folder (Group by Folder), Done (the Done fold),
    /// or needing you past the row limit (it keeps a row out of "Show N more").
    static func movesRows(from old: SidebarWorkspace, to new: SidebarWorkspace, groupsByFolder: Bool) -> Bool {
        if groupsByFolder && old.folder != new.folder { return true }
        if SidebarTunables.doneFold.value && (old.taskStatus == .done) != (new.taskStatus == .done) { return true }
        return SidebarTunables.rowLimit > 0 && (old.agentChip == .needsYou) != (new.agentChip == .needsYou)
    }
}
