import Foundation

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
    /// Show or hide an item's label on an inline line.
    case itemUpdate(LayoutItemID, showsLabel: Bool)
    /// Back to `SidebarLayoutDocument.defaults`.
    case reset

    enum CodingKeys: String, CodingKey {
        case kind, section, index, id, patch, region, item
        case showsLabel = "shows_label"
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
        case "item.update":
            self = .itemUpdate(try c.decode(LayoutItemID.self, forKey: .id), showsLabel: try c.decode(Bool.self, forKey: .showsLabel))
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
        case let .itemUpdate(id, showsLabel):
            try c.encode(id, forKey: .id)
            try c.encode(showsLabel, forKey: .showsLabel)
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
        case .itemUpdate: "item.update"
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
    /// L4: gap outside 0...32 or columns outside 1...12.
    case invalidArrangement = "invalid_arrangement"
    /// L4: over 32 sections or 200 items.
    case tooMany = "too_many"
    /// The same idempotency key with a different op.
    case idempotencyConflict = "idempotency_conflict"
}
