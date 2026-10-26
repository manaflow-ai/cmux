import Foundation

// A Chief dragged in draws, counts as placed and comes off before the daemon answers (#23933). The mirror owns the
// pending change, its order and its rollback, so where the Chief draws is the mirror's row: the Chief's item has one id
// (`chiefItemID`), and the daemon refuses a second item with that id. What the row shows comes from the add itself
// (`SidebarPendingChief`, kept by intent key until its echo, refusal or a load settles it): its fields and the section
// it makes, never an older confirmed record (a Chief removed and added again before either echo). Only the Chief: any
// other item draws at its echo.
extension SidebarLayoutDocument {
    /// The Chief's item id, whatever section or group holds it.
    public static let chiefItemID = LayoutItemID("itm_chief")
}

/// One intent's add of the Chief, not echoed yet: the item it adds and the section it makes for it (Add to Top with no
/// top section yet), or an undo's restore of them, as the document will hold them.
struct SidebarPendingChief: Hashable {
    var item: SidebarDocItem
    var section: SidebarDocSection?

    /// The Chief's add in `ops` (an intent's ops, JSON); nil when they add no Chief.
    init?(ops: Data) {
        guard let list = try? JSONSerialization.jsonObject(with: ops) as? [[String: Any]] else { return nil }
        var item: SidebarDocItem?
        var sections: [String: SidebarDocSection] = [:]
        for op in list {
            switch op["op"] as? String {
            // An add, or an undo's restore (`*.put`, the whole record).
            case "section.add", "section.put":
                if let record = Self.decode(SidebarDocWire.Section.self, op["section"])?.record { sections[record.id] = record }
            case "item.add", "item.put":
                guard var wire = op["item"] as? [String: Any], wire["id"] as? String == SidebarLayoutDocument.chiefItemID.rawValue else { continue }
                if let section = (op["to"] as? [String: Any])?["section"] as? String { wire["section"] = section }
                item = Self.decode(SidebarDocWire.Item.self, wire)?.record
            default:
                continue
            }
        }
        guard let item else { return nil }
        self.item = item
        section = sections[item.section]
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ object: Any?) -> Value? {
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension SidebarDocRecords {
    /// These records with the Chief where the rows draw it (`chiefItemID`): the newest unechoed add's fields
    /// (`pending`, oldest first) over any confirmed record, else the confirmed one, else a plain Chief; and each
    /// section such an add makes that the records lack yet.
    func addingPendingChief(drawnIn rows: [SidebarDocRow], pending: [SidebarPendingChief]) -> SidebarDocRecords {
        let id = SidebarLayoutDocument.chiefItemID.rawValue
        guard pending.isEmpty == false || items[id] == nil, let row = rows.first(where: { $0.item == id }) else { return self }
        var drawn = self
        for section in pending.compactMap(\.section) where drawn.sections[section.id] == nil {
            drawn.sections[section.id] = section
        }
        var item = pending.last?.item ?? items[id] ?? SidebarDocItem(id: id, section: row.section, body: .builtin(SidebarBuiltIn.chief.rawValue))
        (item.section, item.parent) = (row.section, row.parent)
        drawn.items[id] = item
        return drawn
    }
}

extension SidebarDocStore {
    /// The records as the sidebar draws them (`addingPendingChief`): an action finds, moves and removes a Chief dragged
    /// in before the daemon answered, with that add's own fields. No mirror call while no Chief add waits and the
    /// confirmed records hold the Chief.
    var drawnRecords: SidebarDocRecords {
        guard pendingChief.isEmpty == false || records.items[SidebarLayoutDocument.chiefItemID.rawValue] == nil,
              let rows = rows(SidebarViewRequest(live: Array(lastLive))) else { return records }
        return records.addingPendingChief(drawnIn: rows, pending: pendingChief.map(\.add))
    }

    /// The confirmed records less a Chief with an add not echoed: an edit of its own fields waits for that echo, not
    /// for an older Chief's record (one removed and added again).
    var settledRecords: SidebarDocRecords {
        guard pendingChief.isEmpty == false else { return records }
        var settled = records
        settled.items[SidebarLayoutDocument.chiefItemID.rawValue] = nil
        return settled
    }

    /// What an item the rows draw and the confirmed records lack shows: the pending Chief, else nothing known yet.
    static func pendingRef(_ id: String) -> LayoutItemRef? {
        id == SidebarLayoutDocument.chiefItemID.rawValue ? .builtIn(.chief) : nil
    }

    /// Whether item `id` is a drawn Chief whose add has not echoed (a first add, or one after a remove of a confirmed
    /// Chief): its own fields take no edit until then.
    public func isPending(_ id: LayoutItemID) -> Bool {
        guard id == SidebarLayoutDocument.chiefItemID else { return false }
        return pendingChief.isEmpty == false || records.items[id.rawValue] == nil ? drawnRecords.items[id.rawValue] != nil : false
    }

    /// The Chief's add sent under `key` is settled: echoed, refused, dropped or answered by a load.
    /// Whether one was pending.
    @discardableResult
    func settlePendingChief(_ key: String) -> Bool {
        let count = pendingChief.count
        pendingChief.removeAll { $0.key == key }
        return pendingChief.count != count
    }

    /// An echoed batch settles the Chief's add sent under its key: the first `sidebar_doc` marker's, else the batch's
    /// own (as the mirror reads it).
    @discardableResult
    func settlePendingChief(batch data: Data) -> Bool {
        guard let batch = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let markers = (batch["changes"] as? [[String: Any]] ?? []).filter { $0["resource"] as? String == "sidebar_doc" }
        let key = markers.lazy.compactMap { ($0["value"] as? [String: Any])?["idempotency_key"] as? String }.first
            ?? batch["idempotency_key"] as? String
        return key.map { settlePendingChief($0) } ?? false
    }
}
