// Reads one schema file's families, methods and events for MethodTableSchema.
// Mirrors cmux-tui/crates/cmux-ipc/build-support/method_tables.rs rule for rule.

import Foundation

struct MethodTableSchemaReader {
    typealias Schema = MethodTableSchema

    let file: String
    let document: SchemaJSON
    /// Declared family id -> kebab-case name.
    private(set) var declared: [UInt8: String] = [:]

    init(file: String, document: SchemaJSON) {
        self.file = file
        self.document = document
    }

    /// `families: { "<kebab-name>": { "id": <u8>, "description": "..." } }`;
    /// absent means no family yet.
    mutating func declareFamilies(spaces: [Schema.Space]) throws(MethodTableSchemaError) {
        guard let table = document["families"] else { return }
        guard let families = table.object else { throw error("$.families", "must be an object") }
        for name in families.keys.sorted() {
            let path = "$.families.\(name)"
            guard let raw = families[name]?["id"]?.integer, let id = UInt8(exactly: raw) else {
                throw error("\(path).id", "must be a u8")
            }
            guard spaces.contains(where: { $0.range.contains(id) }) else {
                throw error("\(path).id", "\(Self.hex(UInt16(id), width: 2)) is outside this file's family ranges")
            }
            if let other = declared[id] {
                throw error("\(path).id", "\(Self.hex(UInt16(id), width: 2)) is also family \"\(other)\"")
            }
            declared[id] = name
        }
    }

    /// The framed methods under `key` that `client` calls (design 3.3: Swift
    /// generates only methods whose `clients` include its client). Every method
    /// is read and placed first, so this refuses what the Rust reader refuses;
    /// the others then leave their ordinals free, and a family keeps no trailing
    /// free ordinal and no family stays empty.
    func methods(key: String, space: Schema.Space, client: String) throws(MethodTableSchemaError) -> [Schema.Family<Schema.Method>] {
        var grouped: [UInt8: [Schema.Method?]] = [:]
        let entries = try members(key)
        for name in entries.keys.sorted() {
            guard let node = entries[name] else { continue }
            let path = "$.\(key).\(name)"
            guard let id = try wireID(path: path, node: node, key: "method_id") else { continue }
            let row = try method(path: path, name: name, id: id, node: node)
            try place(&grouped, path: "\(path).method_id", id: id, space: space, item: row, name: \.name)
        }
        return finish(grouped.mapValues { (slots: [Schema.Method?]) -> [Schema.Method?] in
            slots.map { slot in
                guard let slot, slot.serves(client) else { return nil }
                return slot
            }
        })
    }

    func events() throws(MethodTableSchemaError) -> [Schema.Family<Schema.Event>] {
        var grouped: [UInt8: [Schema.Event?]] = [:]
        let entries = try members("events")
        for name in entries.keys.sorted() {
            guard let node = entries[name] else { continue }
            let path = "$.events.\(name)"
            guard let id = try wireID(path: path, node: node, key: "event_id") else { continue }
            let event = Schema.Event(
                id: id,
                name: name,
                priority: try priority(path: path, node: node),
                coalesce: try coalesce(path: path, node: node)
            )
            try place(&grouped, path: "\(path).event_id", id: id, space: .events, item: event, name: \.name)
        }
        return finish(grouped)
    }

    // Placing ---------------------------------------------------------------

    /// Places `item` at its family and ordinal; refuses an undeclared family,
    /// a family of another space and a second holder of an id.
    private func place<Row>(
        _ grouped: inout [UInt8: [Row?]],
        path: String,
        id: UInt16,
        space: Schema.Space,
        item: Row,
        name: KeyPath<Row, String>
    ) throws(MethodTableSchemaError) {
        let family = UInt8(truncatingIfNeeded: id >> 8)
        let ordinal = Int(UInt8(truncatingIfNeeded: id))
        guard declared[family] != nil else {
            throw error(path, "family \(Self.hex(UInt16(family), width: 2)) is not declared in $.families")
        }
        guard space.range.contains(family) else {
            let first = Self.hex(UInt16(space.range.lowerBound), width: 2)
            let last = Self.hex(UInt16(space.range.upperBound), width: 2)
            throw error(path, "\(Self.hex(id, width: 4)) is outside families \(first)-\(last)")
        }
        var slots = grouped[family] ?? []
        if slots.count <= ordinal {
            slots.append(contentsOf: Array(repeating: nil, count: ordinal + 1 - slots.count))
        }
        if let existing = slots[ordinal] {
            throw error(path, "\(Self.hex(id, width: 4)) is also held by \"\(existing[keyPath: name])\"")
        }
        slots[ordinal] = item
        grouped[family] = slots
    }

    /// Dense families in id order: trailing free ordinals dropped, empty
    /// families left out.
    private func finish<Row: Equatable>(_ grouped: [UInt8: [Row?]]) -> [Schema.Family<Row>] {
        grouped.keys.sorted().compactMap { id in
            var slots = grouped[id] ?? []
            while let last = slots.last, last == nil { slots.removeLast() }
            return slots.isEmpty ? nil : Schema.Family(id: id, name: declared[id] ?? "", slots: slots)
        }
    }

    // Attributes ------------------------------------------------------------

    private func method(path: String, name: String, id: UInt16, node: SchemaJSON) throws(MethodTableSchemaError) -> Schema.Method {
        let binary = try variant(path: path, node: node, key: "payload",
                                 choices: [("json", "json"), ("binary", "binary")], default: "json") == "binary"
        let layout: UInt8?
        switch (binary, node["layout_version"]) {
        case (false, nil):
            layout = nil
        case (false, .some):
            throw error("\(path).layout_version", "needs payload \"binary\"")
        case (true, let value):
            guard let raw = value?.integer, let version = UInt8(exactly: raw), version >= 1 else {
                throw error("\(path).layout_version", "a binary payload needs a layout version 1-255")
            }
            layout = version
        }
        var crossesStreamOK: String?
        if let value = node["crosses_stream_ok"] {
            guard let reason = value.string, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw error("\(path).crosses_stream_ok", "must be a non-empty reason")
            }
            crossesStreamOK = reason
        }
        var maxBytes: UInt32?
        if let value = node["max_bytes"] {
            guard let raw = value.integer, (1...Schema.maxFrameBytes).contains(raw), let bound = UInt32(exactly: raw) else {
                throw error("\(path).max_bytes", "must be 1-\(Schema.maxFrameBytes)")
            }
            maxBytes = bound
        }
        return Schema.Method(
            id: id,
            name: name,
            priority: try priority(path: path, node: node),
            // Absent ordering is the connection sequence (Mojo: in-order delivery).
            ordering: try variant(path: path, node: node, key: "ordering",
                                  choices: [("sequence", "sequence"), ("independent", "independent")],
                                  default: "sequence"),
            // Durability has no default (spec/transports.md): a framed command
            // states it, as it states its priority.
            durability: try variant(path: path, node: node, key: "durability",
                                    choices: [("read_only", "readOnly"), ("memory", "memory"),
                                              ("reply_before_journal", "replyBeforeJournal"),
                                              ("reply_after_journal", "replyAfterJournal")],
                                    default: nil),
            binaryLayout: layout,
            streamScoped: try flag(path: path, node: node, key: "stream_scoped"),
            crossesStreamOK: crossesStreamOK,
            maxBytes: maxBytes,
            coalesce: try coalesce(path: path, node: node),
            urgent: try flag(path: path, node: node, key: "urgent"),
            clients: try clients(path: path, node: node)
        )
    }

    /// `clients`, when present, is a non-empty array of client names; absent
    /// means every client (spec/transports.md).
    private func clients(path: String, node: SchemaJSON) throws(MethodTableSchemaError) -> [String]? {
        guard let value = node["clients"] else { return nil }
        let refusal = error("\(path).clients", "must be a non-empty array of client names")
        guard case .array(let items) = value, !items.isEmpty else { throw refusal }
        var out: [String] = []
        for item in items {
            guard let name = item.string else { throw refusal }
            out.append(name)
        }
        return out
    }

    private func priority(path: String, node: SchemaJSON) throws(MethodTableSchemaError) -> String {
        try variant(path: path, node: node, key: "priority",
                    choices: [("input", "input"), ("control", "control"),
                              ("bulk", "bulk"), ("background", "background")],
                    default: nil)
    }

    /// Maps a schema string to a Swift case name; absent gives `default`.
    private func variant(
        path: String,
        node: SchemaJSON,
        key: String,
        choices: [(wire: String, swift: String)],
        default fallback: String?
    ) throws(MethodTableSchemaError) -> String {
        guard let value = node[key] else {
            guard let fallback else { throw error(path, "a method with an id needs \(key)") }
            return fallback
        }
        guard let text = value.string, let choice = choices.first(where: { $0.wire == text }) else {
            throw error("\(path).\(key)", "must be one of \(choices.map(\.wire).joined(separator: ", "))")
        }
        return choice.swift
    }

    private func flag(path: String, node: SchemaJSON, key: String) throws(MethodTableSchemaError) -> Bool {
        guard let value = node[key] else { return false }
        guard let set = value.bool else { throw error("\(path).\(key)", "must be a boolean") }
        return set
    }

    private func coalesce(path: String, node: SchemaJSON) throws(MethodTableSchemaError) -> Schema.Coalesce? {
        guard let value = node["coalesce"] else { return nil }
        guard value.object != nil else { throw error("\(path).coalesce", "must be an object") }
        return Schema.Coalesce(
            key: try names(path: "\(path).coalesce.key", value: value["key"]),
            additive: try names(path: "\(path).coalesce.additive", value: value["additive"])
        )
    }

    private func names(path: String, value: SchemaJSON?) throws(MethodTableSchemaError) -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value else { throw error(path, "must be an array of field names") }
        var out: [String] = []
        for item in items {
            guard let name = item.string else { throw error(path, "must be an array of field names") }
            out.append(name)
        }
        return out
    }

    // Plumbing --------------------------------------------------------------

    private func members(_ key: String) throws(MethodTableSchemaError) -> [String: SchemaJSON] {
        guard let members = document[key]?.object else { throw error("$.\(key)", "must be an object") }
        return members
    }

    private func wireID(path: String, node: SchemaJSON, key: String) throws(MethodTableSchemaError) -> UInt16? {
        guard let value = node[key] else { return nil }
        guard let raw = value.integer, let id = UInt16(exactly: raw) else {
            throw error("\(path).\(key)", "must be a u16 (family << 8 | ordinal)")
        }
        return id
    }

    private func error(_ path: String, _ message: String) -> MethodTableSchemaError {
        MethodTableSchemaError(file: file, path: path, message: message)
    }

    static func hex(_ value: UInt16, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
