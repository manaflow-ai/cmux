import Foundation

// A Chief dragged in draws, counts as placed and comes off before the daemon answers (#23933). The mirror owns the
// pending change and its rollback; the client keeps no record of its own. The Chief's item has one id
// (`chiefItemID`), so the mirror's row names it: it lives exactly as long as the mirror draws it (until the add is
// confirmed, refused or undone; a refused remove puts it back), and the daemon refuses a second item with that id.
// Only the Chief: any other item draws at its echo.
extension SidebarLayoutDocument {
    /// The Chief's item id, whatever section or group holds it.
    public static let chiefItemID = LayoutItemID("itm_chief")
}

extension SidebarDocRecords {
    /// These records and the Chief the rows draw before its echo (`chiefItemID`), where they draw it.
    func addingPendingChief(drawnIn rows: [SidebarDocRow]) -> SidebarDocRecords {
        let id = SidebarLayoutDocument.chiefItemID.rawValue
        guard items[id] == nil, let row = rows.first(where: { $0.item == id }) else { return self }
        var drawn = self
        drawn.items[id] = SidebarDocItem(id: id, section: row.section, parent: row.parent, body: .builtin(SidebarBuiltIn.chief.rawValue))
        return drawn
    }
}

extension SidebarDocStore {
    /// The records as the sidebar draws them (`addingPendingChief`): an action finds, moves and removes a Chief dragged
    /// in before the daemon answered. One mirror call unless the confirmed records hold the Chief's id.
    var drawnRecords: SidebarDocRecords {
        guard records.items[SidebarLayoutDocument.chiefItemID.rawValue] == nil,
              let rows = rows(SidebarViewRequest(live: Array(lastLive))) else { return records }
        return records.addingPendingChief(drawnIn: rows)
    }

    /// What an item the rows draw and the confirmed records lack shows: the pending Chief, else nothing known yet.
    static func pendingRef(_ id: String) -> LayoutItemRef? {
        id == SidebarLayoutDocument.chiefItemID.rawValue ? .builtIn(.chief) : nil
    }

    /// Whether item `id` is the Chief drawn before its add's echo: its own fields take no edit until then.
    public func isPending(_ id: LayoutItemID) -> Bool {
        id == SidebarLayoutDocument.chiefItemID && records.items[id.rawValue] == nil && drawnRecords.items[id.rawValue] != nil
    }
}
