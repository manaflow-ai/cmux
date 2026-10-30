import Foundation

extension SidebarModel {
    /// A content change that changes which rows the list draws: a folder (Group by Folder), Done (the Done fold),
    /// needing you past the row limit (it keeps a row out of "Show N more"), or the listed tabs.
    static func movesRows(from old: SidebarWorkspace, to new: SidebarWorkspace, groupsByFolder: Bool, listsTabs: Bool) -> Bool {
        if groupsByFolder && old.folder != new.folder { return true }
        if SidebarTunables.doneFold.value && old.finishedForSidebarFold != new.finishedForSidebarFold { return true }
        if SidebarTunables.rowLimit > 0 && (old.agentChip == .needsYou) != (new.agentChip == .needsYou) { return true }
        return listsTabs && !old.tabs.elementsEqual(new.tabs) { $0.id == $1.id && $0.kind == $1.kind }
    }
}


private extension SidebarWorkspace {
    /// The layout's finished fold follows the agent chat state as well as the explicit task lane.
    var finishedForSidebarFold: Bool {
        if taskStatus == .done { return true }
        switch agentChip {
        case .done?, .failed?, .lost?: return true
        case .needsYou?, .ciFailing?, .working?, .idle?, nil: return false
        }
    }
}
