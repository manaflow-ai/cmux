import Foundation

/// Set or clear an optional field. Absent from a patch = keep.
public nonisolated enum OptionalUpdate<Value: Hashable & Sendable & Codable>: Hashable, Sendable {
    case set(Value)
    case clear

    public var value: Value? {
        if case .set(let value) = self { return value }
        return nil
    }
}

/// Fields `section.update` changes; nil keeps a field.
public nonisolated struct SectionPatch: Hashable, Sendable, Codable {
    public var title: OptionalUpdate<String>?
    public var look: SectionLook?
    public var room: OptionalUpdate<String>?
    public var maxRows: OptionalUpdate<Int>?

    public init(title: OptionalUpdate<String>? = nil, look: SectionLook? = nil, room: OptionalUpdate<String>? = nil,
                maxRows: OptionalUpdate<Int>? = nil) {
        self.title = title
        self.look = look
        self.room = room
        self.maxRows = maxRows
    }

    enum CodingKeys: String, CodingKey {
        case title, look, room
        case maxRows = "max_rows"
    }

    // Wire: a missing key keeps the field, null clears it, a value sets it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try Self.decode(String.self, .title, c)
        look = try c.decodeIfPresent(SectionLook.self, forKey: .look)
        room = try Self.decode(String.self, .room, c)
        maxRows = try Self.decode(Int.self, .maxRows, c)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try Self.encode(title, .title, &c)
        try c.encodeIfPresent(look, forKey: .look)
        try Self.encode(room, .room, &c)
        try Self.encode(maxRows, .maxRows, &c)
    }

    private static func decode<T>(_ type: T.Type, _ key: CodingKeys, _ c: KeyedDecodingContainer<CodingKeys>) throws -> OptionalUpdate<T>? {
        guard c.contains(key) else { return nil }
        if try c.decodeNil(forKey: key) { return .clear }
        return .set(try c.decode(T.self, forKey: key))
    }

    private static func encode<T>(_ update: OptionalUpdate<T>?, _ key: CodingKeys, _ c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch update {
        case nil: break
        case .clear: try c.encodeNil(forKey: key)
        case .set(let value): try c.encode(value, forKey: key)
        }
    }
}

/// One change to the layout (plans/cmux-next/sidebar-sections.md 4). The
/// owner applies it with `SidebarLayoutReducer` under an idempotency key.
public nonisolated enum SidebarLayoutOp: Hashable, Sendable, Codable {
    /// Insert a section at `index` among its region's sections.
    case sectionAdd(LayoutSection, index: Int)
    case sectionUpdate(LayoutSectionID, SectionPatch)
    /// Move a section to `region` at `index` among that region's sections
    /// (excluding itself).
    case sectionMove(LayoutSectionID, region: SidebarRegion, index: Int)
    case sectionRemove(LayoutSectionID)
    case itemAdd(LayoutItem, section: LayoutSectionID, index: Int)
    /// Move an item to `section` at `index` (excluding itself).
    case itemMove(LayoutItemID, section: LayoutSectionID, index: Int)
    case itemRemove(LayoutItemID)
    /// Back to `SidebarLayoutDocument.defaults`.
    case reset

    enum CodingKeys: String, CodingKey {
        case kind, section, index, id, patch, region, item
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "section.add":
            self = .sectionAdd(try c.decode(LayoutSection.self, forKey: .section), index: try c.decode(Int.self, forKey: .index))
        case "section.update":
            self = .sectionUpdate(try c.decode(LayoutSectionID.self, forKey: .id), try c.decode(SectionPatch.self, forKey: .patch))
        case "section.move":
            self = .sectionMove(try c.decode(LayoutSectionID.self, forKey: .id), region: try c.decode(SidebarRegion.self, forKey: .region),
                                index: try c.decode(Int.self, forKey: .index))
        case "section.remove":
            self = .sectionRemove(try c.decode(LayoutSectionID.self, forKey: .id))
        case "item.add":
            self = .itemAdd(try c.decode(LayoutItem.self, forKey: .item), section: try c.decode(LayoutSectionID.self, forKey: .section),
                            index: try c.decode(Int.self, forKey: .index))
        case "item.move":
            self = .itemMove(try c.decode(LayoutItemID.self, forKey: .id), section: try c.decode(LayoutSectionID.self, forKey: .section),
                             index: try c.decode(Int.self, forKey: .index))
        case "item.remove":
            self = .itemRemove(try c.decode(LayoutItemID.self, forKey: .id))
        case "layout.reset":
            self = .reset
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown sidebar layout op \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case let .sectionAdd(section, index):
            try c.encode(section, forKey: .section)
            try c.encode(index, forKey: .index)
        case let .sectionUpdate(id, patch):
            try c.encode(id, forKey: .id)
            try c.encode(patch, forKey: .patch)
        case let .sectionMove(id, region, index):
            try c.encode(id, forKey: .id)
            try c.encode(region, forKey: .region)
            try c.encode(index, forKey: .index)
        case let .sectionRemove(id):
            try c.encode(id, forKey: .id)
        case let .itemAdd(item, section, index):
            try c.encode(item, forKey: .item)
            try c.encode(section, forKey: .section)
            try c.encode(index, forKey: .index)
        case let .itemMove(id, section, index):
            try c.encode(id, forKey: .id)
            try c.encode(section, forKey: .section)
            try c.encode(index, forKey: .index)
        case let .itemRemove(id):
            try c.encode(id, forKey: .id)
        case .reset:
            break
        }
    }

    /// The wire tag.
    public var kind: String {
        switch self {
        case .sectionAdd: "section.add"
        case .sectionUpdate: "section.update"
        case .sectionMove: "section.move"
        case .sectionRemove: "section.remove"
        case .itemAdd: "item.add"
        case .itemMove: "item.move"
        case .itemRemove: "item.remove"
        case .reset: "layout.reset"
        }
    }
}

/// Why the owner refused an op. Raw values are the wire reasons.
public nonisolated enum SidebarLayoutReject: String, Error, Hashable, Sendable, Codable {
    /// L1: the workspaces section cannot be removed, duplicated or given items.
    case workspacesRequired = "workspaces_required"
    case unknownSection = "unknown_section"
    case unknownItem = "unknown_item"
    /// L2: an id already in use.
    case duplicateID = "duplicate_id"
    /// L3: the target section already holds this reference.
    case duplicateRef = "duplicate_ref"
    /// L4: empty or over 80 characters.
    case invalidTitle = "invalid_title"
    /// L4: outside 1...50.
    case invalidMaxRows = "invalid_max_rows"
    /// L4: over 32 sections or 200 items.
    case tooMany = "too_many"
    /// The same idempotency key with a different op.
    case idempotencyConflict = "idempotency_conflict"
}
