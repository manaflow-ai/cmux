import Foundation

/// What pending sidebar-document changes write on item records (#26382): a group's name, color or
/// icon (`group.update`), a new group (`group.create`, with its space) and an item's own fields (`item.update`: its
/// space, label, span, icon). The mirror's rows place every pending
/// change at once, but the rows draw names, colors and icons from the records, and the confirmed
/// records change only with the daemon's batch: a rename, a recolor or New Group showed only after
/// the echo. Each change's writes hold from its intent until its key settles (its batch applied, a
/// refusal, a no-op reply, or a load after the reply); `applied(to:)` lays them over the confirmed
/// records in order, at read time, so a confirmed change to another field still shows.
nonisolated struct SidebarDocPendingRecords {
    private enum Write {
        /// `group.update`: each field nil when the patch leaves it; a nil inner value clears it.
        case update(id: String, name: String?, color: String??, icon: String??)
        case create(SidebarDocItem)
        /// `item.update`: each field nil when the patch leaves it; a nil inner value clears it.
        case item(id: String, patch: ItemPatch)
    }

    /// The fields of an `item.update` patch the records hold. A link, tab or app moved into Pinned stores the acting
    /// window's space (`room`) in the same change: without it the optimistic rows read the old space and the item left
    /// that window until the echo.
    private struct ItemPatch {
        var room: String??
        var showsLabel: Bool?
        var span: Int??
        var label: String??
        var iconURL: String??

        var isEmpty: Bool { room == nil && showsLabel == nil && span == nil && label == nil && iconURL == nil }

        func applied(to item: SidebarDocItem) -> SidebarDocItem {
            var item = item
            if let room { item.room = room }
            if let showsLabel { item.showsLabel = showsLabel }
            if let span { item.span = span }
            if let label { item.label = label }
            if let iconURL { item.iconURL = iconURL }
            return item
        }
    }

    private struct Entry {
        var key: String
        var writes: [Write]
        /// The daemon answered: only its batch (or a load) is still to come.
        var replied = false
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Notes what `ops` (a `sidebar.apply` op array, as JSON) write on records, under `key`. False when they write none
    /// (a move, a pin, a fold: the mirror's rows show those, or the window's fold does).
    @discardableResult
    mutating func add(key: String, ops: Data, records: SidebarDocRecords) -> Bool {
        guard let ops = try? JSONSerialization.jsonObject(with: ops) as? [[String: Any]] else { return false }
        let writes = ops.compactMap { Self.write($0, records: records) }
        guard !writes.isEmpty else { return false }
        entries.append(Entry(key: key, writes: writes))
        return true
    }

    /// Ends `key`'s writes; true when it had some.
    @discardableResult
    mutating func remove(_ key: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// The daemon answered `key`: a load from here on has its writes.
    mutating func noteReplied(_ key: String) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[index].replied = true
    }

    /// The keys the daemon has answered: a load asked for from here on holds their changes (or never will).
    var replied: Set<String> { Set(entries.filter(\.replied).map(\.key)) }

    /// `records` with every pending write applied, in order.
    func applied(to records: SidebarDocRecords) -> SidebarDocRecords {
        var records = records
        for write in entries.flatMap(\.writes) {
            switch write {
            case let .update(id, name, color, icon):
                guard var item = records.items[id], case let .group(oldName, oldColor, oldIcon, collapsed) = item.body else { continue }
                item.body = .group(name: name ?? oldName, color: color ?? oldColor, icon: icon ?? oldIcon, collapsed: collapsed)
                records.items[id] = item
            case let .create(item):
                if records.items[item.id] == nil { records.items[item.id] = item }
            case let .item(id, patch):
                guard let item = records.items[id] else { continue }
                records.items[id] = patch.applied(to: item)
            }
        }
        return records
    }

    /// The record write of one op, or nil. A fold (`collapsed` alone) writes nothing: the window shows it already.
    private static func write(_ op: [String: Any], records: SidebarDocRecords) -> Write? {
        guard let id = op["id"] as? String else { return nil }
        switch op["op"] as? String {
        case "group.update":
            guard let patch = op["patch"] as? [String: Any] else { return nil }
            let name = patch["name"] as? String, color = field(patch, "color"), icon = field(patch, "icon")
            guard name != nil || color != nil || icon != nil else { return nil }
            return .update(id: id, name: name, color: color, icon: icon)
        case "group.create":
            let to = op["to"] as? [String: Any]
            let first = (op["items"] as? [String])?.first.flatMap { records.items[$0] }
            let section = to?["section"] as? String ?? first?.section ?? ""
            let parent = to?["parent"] as? String ?? (to?["section"] == nil ? first?.parent : nil)
            return .create(SidebarDocItem(id: id, section: section, parent: parent,
                                          body: .group(name: op["name"] as? String ?? "", color: op["color"] as? String, icon: nil, collapsed: false),
                                          room: op["profile"] as? String))
        case "item.update":
            guard let wire = op["patch"] as? [String: Any] else { return nil }
            let patch = ItemPatch(room: field(wire, "room"), showsLabel: wire["shows_label"] as? Bool,
                                  span: wire["span"].map { $0 as? Int }, label: field(wire, "label"), iconURL: field(wire, "icon_url"))
            return patch.isEmpty ? nil : .item(id: id, patch: patch)
        default:
            return nil
        }
    }

    /// A patch field: nil when absent, `.some(nil)` when it clears (JSON null), else its string.
    private static func field(_ patch: [String: Any], _ key: String) -> String?? {
        guard let value = patch[key] else { return nil }
        return .some(value as? String)
    }
}
