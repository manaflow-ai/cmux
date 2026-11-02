import Foundation

/// What pending sidebar-document changes write on item records (#26382): a group's name, color or
/// icon (`group.update`) and a new group (`group.create`). The mirror's rows place every pending
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
                                          body: .group(name: op["name"] as? String ?? "", color: op["color"] as? String, icon: nil, collapsed: false)))
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
