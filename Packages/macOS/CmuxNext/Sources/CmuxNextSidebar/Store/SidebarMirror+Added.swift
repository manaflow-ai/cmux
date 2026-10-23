import Foundation

extension SidebarMirror {
    /// The built-ins `ops` (a JSON array, as the mirror stamped it) add, each as its record: `item.add` names the id and
    /// the body; where it sits comes from the rows (`SidebarDocRecords.adding`). A change's rows hold such an item at
    /// once; the confirmed records only after its batch. Only a built-in (the Chief) draws before its echo: its record
    /// takes no edit until then (`LayoutOpPlanner` plans edits over the confirmed records), so it is never stale. Any
    /// other item draws at its echo, as before.
    nonisolated static func addedItems(in ops: Data) -> [String: SidebarDocItem] {
        guard let list = (try? JSONSerialization.jsonObject(with: ops)) as? [[String: Any]] else { return [:] }
        var items: [String: SidebarDocItem] = [:]
        for op in list where op["op"] as? String == "item.add" {
            guard var item = op["item"] as? [String: Any], let id = item["id"] as? String else { continue }
            item["section"] = ""
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  let wire = try? JSONDecoder().decode(SidebarDocWire.Item.self, from: data) else { continue }
            let record = wire.record
            if case .builtin = record.body { items[id] = record }
        }
        return items
    }

    /// Forgets the added items the rows no longer draw unconfirmed: a batch confirmed them (`confirmed` holds them), or
    /// the change was refused or undone (the rows lost them). Keeps `added` to the changes still in flight.
    func keepAdded(drawnIn rows: [SidebarDocRow], confirmed: SidebarDocRecords) {
        guard !added.isEmpty else { return }
        let drawn = Set(rows.compactMap(\.item))
        let kept = added.filter { drawn.contains($0.key) && confirmed.items[$0.key] == nil }
        if kept.count != added.count { added = kept }
    }
}

extension SidebarDocRecords {
    /// These records and the items a change not yet echoed added (`pending`, by id), each where `rows` (the mirror's)
    /// draw it: the sidebar draws, finds, moves and removes a pending item as a confirmed one.
    func adding(pending: [String: SidebarDocItem], drawnIn rows: [SidebarDocRow]) -> SidebarDocRecords {
        guard !pending.isEmpty else { return self }
        var drawn = self
        for row in rows {
            guard let id = row.item, drawn.items[id] == nil, var item = pending[id] else { continue }
            (item.section, item.parent) = (row.section, row.parent)
            drawn.items[id] = item
        }
        return drawn
    }
}

extension SidebarDocStore {
    /// The records as the sidebar draws them (`SidebarDocRecords.adding`): an action finds, moves and removes a Chief
    /// dragged in before the daemon answered. One mirror call while a change that added an item is in flight; none otherwise.
    var drawnRecords: SidebarDocRecords {
        guard let pending = mirror?.added, !pending.isEmpty, let rows = rows(SidebarViewRequest(live: Array(lastLive))) else { return records }
        return records.adding(pending: pending, drawnIn: rows)
    }
}
