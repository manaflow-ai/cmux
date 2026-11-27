import Foundation

/// What pending sidebar-document changes write on item records (#26382): a group's name, color or
/// icon (`group.update`), a new group (`group.create`, with its space) and an item's own fields (`item.update`: its
/// space, label, span, icon). The mirror's rows place every pending
/// change at once, but the rows draw names, colors and icons from the records, and the confirmed
/// records change only with the daemon's batch: a rename, a recolor or New Group showed only after
/// the echo. Each change's writes hold from its intent until its key settles (its batch applied, a
/// refusal, a no-op reply, or a load after the reply); `applied(to:)` lays them over the confirmed
/// records in order, at read time, so a confirmed change to another field still shows. The rules (which ops write
/// what, and how the writes lay over records) are Rust's (`sidebar_pending_records`, cmux-layout-reducer); which keys
/// are pending stays here.
nonisolated struct SidebarDocPendingRecords {
    /// One change's writes, as the rules answered them (`sidebar_pending_records`): each write's JSON, in order, and
    /// the records it reads or writes.
    private struct Entry {
        var key: String
        var writes: [Data]
        var ids: Set<String>
        /// The daemon answered: only its batch (or a load) is still to come.
        var replied = false
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Notes what `ops` (a `sidebar.apply` op array, as JSON) write on records, under `key`. False when they write none
    /// (a move, a pin, a fold: the mirror's rows show those, or the window's fold does), or when the rules refuse them.
    @discardableResult
    mutating func add(key: String, ops: Data, records: SidebarDocRecords) -> Bool {
        guard let list = try? JSONSerialization.jsonObject(with: ops) as? [[String: Any]] else { return false }
        // A new group takes its space and place from its first item: only those records go along.
        let named = Set(list.compactMap { ($0["items"] as? [String])?.first })
        guard let reply = Self.call(op: "writes", field: "ops", json: ops, items: named, records: records),
              let writes = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["writes"] as? [[String: Any]],
              !writes.isEmpty else { return false }
        var datas: [Data] = [], ids: Set<String> = []
        for write in writes {
            guard let data = try? JSONSerialization.data(withJSONObject: write) else { return false }
            datas.append(data)
            if let id = (write.values.first as? [String: Any])?["id"] as? String { ids.insert(id) }
        }
        entries.append(Entry(key: key, writes: datas, ids: ids))
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

    /// `records` with every pending write applied, in order (`sidebar_pending_records` `apply`, over only the records
    /// the writes touch). The confirmed records when the rules refuse.
    func applied(to records: SidebarDocRecords) -> SidebarDocRecords {
        guard !entries.isEmpty else { return records }
        let ids = entries.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
        let writes = Data("[".utf8) + Data(entries.flatMap(\.writes).joined(separator: Data(",".utf8))) + Data("]".utf8)
        guard let reply = Self.call(op: "apply", field: "writes", json: writes, items: ids, records: records),
              let items = try? JSONDecoder().decode(Applied.self, from: reply).items else { return records }
        var records = records
        for (id, wire) in items {
            if var item = records.items[id] {
                item.room = wire.room
                item.showsLabel = wire.showsLabel
                item.span = wire.span
                item.label = wire.label
                item.iconURL = wire.iconURL
                if case let .group(_, _, _, collapsed) = item.body, let group = wire.group {
                    item.body = .group(name: group.name, color: group.color, icon: group.icon, collapsed: collapsed)
                }
                records.items[id] = item
            } else if let group = wire.group {
                records.items[id] = SidebarDocItem(id: id, section: wire.section, parent: wire.parent,
                                                   body: .group(name: group.name, color: group.color, icon: group.icon, collapsed: group.collapsed),
                                                   showsLabel: wire.showsLabel, span: wire.span, label: wire.label, iconURL: wire.iconURL,
                                                   room: wire.room)
            }
        }
        return records
    }

    // MARK: The wire (cmux-layout-reducer sidebar_pending_records.rs)

    /// The fields of an item record the rules read or write (`Item`); `group` only for a group.
    private struct Item: Codable {
        struct Group: Codable {
            var name: String
            var color: String?
            var icon: String?
            var collapsed: Bool
        }

        var id: String
        var section: String
        var parent: String?
        var group: Group?
        var showsLabel: Bool
        var span: Int?
        var label: String?
        var iconURL: String?
        var room: String?

        enum CodingKeys: String, CodingKey {
            case id, section, parent, group, span, label, room
            case showsLabel = "shows_label"
            case iconURL = "icon_url"
        }

        init(_ item: SidebarDocItem) {
            id = item.id
            section = item.section
            parent = item.parent
            if case let .group(name, color, icon, collapsed) = item.body {
                group = Group(name: name, color: color, icon: icon, collapsed: collapsed)
            }
            showsLabel = item.showsLabel
            span = item.span
            label = item.label
            iconURL = item.iconURL
            room = item.room
        }
    }

    private struct Applied: Decodable {
        var items: [String: Item]
    }

    /// One `sidebar_pending_records` call: `{"op": op, field: json, "items": the records named by ids}`.
    private static func call(op: String, field: String, json: Data, items ids: Set<String>, records: SidebarDocRecords) -> Data? {
        let items = Dictionary(uniqueKeysWithValues: ids.compactMap { id in records.items[id].map { (id, Item($0)) } })
        guard let itemsJSON = try? JSONEncoder().encode(items) else { return nil }
        let request = Data("{\"op\":\"\(op)\",\"\(field)\":".utf8) + json + Data(",\"items\":".utf8) + itemsJSON + Data("}".utf8)
        return RustSidebarClient.reply("sidebar_pending_records", json: request)
    }
}
