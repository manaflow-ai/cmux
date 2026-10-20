public import Foundation

// The sidebar document as the client reads it (`sidebar-doc-v1`,
// .cmux-scratch/sidebar-rewrite/CONTRACT.md): ordered sections of ordered
// items. The daemon owns it; the Rust reducer (through `SidebarMirror`)
// orders and judges it. Swift keeps only the records (names, bodies) the
// rows draw, by id, and never computes an order or a rule from them.

/// A workspace on one machine: its session and its public workspace id.
public nonisolated struct SidebarDocWorkspaceRef: Hashable, Sendable, Codable {
    public var sessionID: String
    public var workspaceID: String

    public init(sessionID: String, workspaceID: String) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case workspaceID = "workspace_id"
    }
}

/// What a section is. Unknown kinds (a newer daemon) are kept by name.
public nonisolated enum SidebarDocSectionKind: Hashable, Sendable {
    /// One machine's workspaces (`sec_m_<session>`).
    case machine(session: String)
    /// The first section, no header by default (`sec_pinned`).
    case pinned
    case custom
    case app(contribution: String?)
    case builtin
    case other(String)
}

/// One section record.
public nonisolated struct SidebarDocSection: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SidebarDocSectionKind
    public var title: String?
    public var showsTitle: Bool
    public var region: SidebarRegion
    public var look: SectionLook
    public var arrangement: SectionArrangement
    public var room: String?
    public var maxRows: Int?
    public var keepsClosed: Bool

    public init(id: String, kind: SidebarDocSectionKind, title: String? = nil, showsTitle: Bool = false, region: SidebarRegion = .middle,
                look: SectionLook = .list, arrangement: SectionArrangement = .list, room: String? = nil, maxRows: Int? = nil,
                keepsClosed: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.showsTitle = showsTitle
        self.region = region
        self.look = look
        self.arrangement = arrangement
        self.room = room
        self.maxRows = maxRows
        self.keepsClosed = keepsClosed
    }

    /// The machine this section lists, or nil.
    public var session: String? {
        if case .machine(let session) = kind { session } else { nil }
    }
}

/// What an item is.
public nonisolated enum SidebarDocBody: Hashable, Sendable {
    case workspace(SidebarDocWorkspaceRef)
    case group(name: String, color: String?, icon: String?, collapsed: Bool)
    case builtin(String)
    case app(String)
    case url(String, title: String?)
    case tab(String)
    case room(String)
    case savedGroup(String)
    /// Any other layout ref, by kind and value.
    case ref(kind: String, value: String)
    case other(String)

    /// The workspace an item names, or nil.
    public var workspace: SidebarDocWorkspaceRef? {
        if case .workspace(let ref) = self { ref } else { nil }
    }

    public var isGroup: Bool {
        if case .group = self { true } else { false }
    }
}

/// One item record.
public nonisolated struct SidebarDocItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var section: String
    public var parent: String?
    public var body: SidebarDocBody
    public var showsLabel: Bool
    public var span: Int?
    /// The name stored with the item (a closed workspace draws it).
    public var label: String?
    /// A url item's page icon address (body `icon_url`): the favicon its row draws.
    public var iconURL: String?

    public init(id: String, section: String, parent: String? = nil, body: SidebarDocBody, showsLabel: Bool = true, span: Int? = nil,
                label: String? = nil, iconURL: String? = nil) {
        self.iconURL = iconURL
        self.id = id
        self.section = section
        self.parent = parent
        self.body = body
        self.showsLabel = showsLabel
        self.span = span
        self.label = label
    }
}

/// One row of the mirror's `view`: the flat order the sidebar draws.
public nonisolated struct SidebarDocRow: Hashable, Sendable, Decodable {
    public var key: String
    /// `section`, `item` (a workspace, a link, a tile...), `group`.
    public var kind: String
    public var section: String
    public var parent: String?
    public var depth: Int
    public var item: String?
    /// A closed workspace kept by a section that keeps closed items.
    public var dimmed: Bool
    public var ref: SidebarDocWorkspaceRef?

    public init(key: String, kind: String, section: String, parent: String? = nil, depth: Int = 0, item: String? = nil, dimmed: Bool = false,
                ref: SidebarDocWorkspaceRef? = nil) {
        self.key = key
        self.kind = kind
        self.section = section
        self.parent = parent
        self.depth = depth
        self.item = item
        self.dimmed = dimmed
        self.ref = ref
    }

    enum CodingKeys: String, CodingKey { case key, kind, section, parent, depth, item, dimmed, ref }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "item"
        section = try c.decode(String.self, forKey: .section)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        item = try c.decodeIfPresent(String.self, forKey: .item)
        dimmed = try c.decodeIfPresent(Bool.self, forKey: .dimmed) ?? false
        ref = try? c.decodeIfPresent(SidebarDocWorkspaceRef.self, forKey: .ref)
    }
}

/// What a drop next to (or into) one row may do, from `drag_begin`.
public nonisolated struct SidebarDocAcceptance: Hashable, Sendable, Decodable {
    public var before: Bool
    public var into: Bool
    public var after: Bool
    /// Why nothing is accepted (`cross_machine`, `provider_owned`...).
    public var refusal: String?

    public init(before: Bool, into: Bool, after: Bool, refusal: String? = nil) {
        self.before = before
        self.into = into
        self.after = after
        self.refusal = refusal
    }

    enum CodingKeys: String, CodingKey { case before, into, after, refusal }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        before = try c.decodeIfPresent(Bool.self, forKey: .before) ?? false
        into = try c.decodeIfPresent(Bool.self, forKey: .into) ?? false
        after = try c.decodeIfPresent(Bool.self, forKey: .after) ?? false
        refusal = try c.decodeIfPresent(String.self, forKey: .refusal)
    }

    public static let none = SidebarDocAcceptance(before: false, into: false, after: false)
}

/// Where a move puts its items: a section, optionally a group in it, and
/// an anchor item (`before` / `after`) or an index. An anchor names an item
/// the person saw, so a move works the same while the list is filtered.
public nonisolated struct SidebarDocTarget: Hashable, Sendable, Encodable {
    public var section: String
    public var parent: String?
    public var before: String?
    public var after: String?
    public var index: Int?

    public init(section: String, parent: String? = nil, before: String? = nil, after: String? = nil, index: Int? = nil) {
        self.section = section
        self.parent = parent
        self.before = before
        self.after = after
        self.index = index
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(section, forKey: .section)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(before, forKey: .before)
        try c.encodeIfPresent(after, forKey: .after)
        try c.encodeIfPresent(index, forKey: .index)
    }

    enum CodingKeys: String, CodingKey { case section, parent, before, after, index }
}

/// The records of the confirmed document, by id: what the rows draw.
/// Changed only by `sidebar.get` and by the daemon's batches (upsert or
/// delete by id); the order comes from the mirror's `view`.
public nonisolated struct SidebarDocRecords: Hashable, Sendable {
    public var revision: UInt64 = 0
    public var sections: [String: SidebarDocSection] = [:]
    public var items: [String: SidebarDocItem] = [:]

    public init(revision: UInt64 = 0, sections: [String: SidebarDocSection] = [:], items: [String: SidebarDocItem] = [:]) {
        self.revision = revision
        self.sections = sections
        self.items = items
    }

    /// The item that places `ref`, or nil.
    public func item(for ref: SidebarDocWorkspaceRef) -> SidebarDocItem? {
        items.values.first { $0.body.workspace == ref }
    }

    /// Records from a `sidebar.get` reply.
    public init(document data: Data) throws {
        let wire = try JSONDecoder().decode(SidebarDocWire.Document.self, from: data)
        revision = wire.revision.value ?? 0
        for section in wire.sections.compactMap(\.value) { sections[section.id] = section.record }
        for item in wire.items.compactMap(\.value) { items[item.id] = item.record }
    }

    /// Applies one batch's `state_upsert` / `state_delete` changes.
    public mutating func apply(batch data: Data) {
        guard let batch = try? JSONDecoder().decode(SidebarDocWire.Batch.self, from: data) else { return }
        for change in batch.changes.compactMap(\.value) {
            switch (change.kind, change.resource) {
            case ("state_upsert", "sidebar_section"):
                if let section = change.section { sections[section.id] = section.record }
            case ("state_delete", "sidebar_section"):
                sections[change.id] = nil
            case ("state_upsert", "sidebar_item"):
                if let item = change.item { items[item.id] = item.record }
            case ("state_delete", "sidebar_item"):
                items[change.id] = nil
            default:
                break
            }
        }
        if let revision = batch.revision?.value { self.revision = revision }
    }

    /// The group item of personal group `id`: `itm_g_<id>` (migrated or
    /// synced from the personal store), else `id` itself (a group the
    /// document made); nil when neither is a group.
    public func groupItem(personal id: String) -> String? {
        [Self.groupItemPrefix + id, id].first { items[$0]?.body.isGroup == true }
    }

    /// Group item `item` sits in Pinned.
    public func isPinned(group item: String) -> Bool {
        items[item].map { $0.body.isGroup && $0.section == SidebarDocStore.pinnedSection } ?? false
    }

    /// `table` with no drop in Pinned unless every dragged item is in Pinned already: a
    /// workspace or group dragged from the list never lands between pinned items and so
    /// never becomes a pin by a drop (Pin is the way in). Pinned items still reorder there.
    public func keepingPinned(_ table: [String: SidebarDocAcceptance], dragging dragged: [String]) -> [String: SidebarDocAcceptance] {
        let pinned = SidebarDocStore.pinnedSection
        guard dragged.contains(where: { items[$0]?.section != pinned }) else { return table }
        var table = table
        for key in table.keys where key == pinned || items[key]?.section == pinned {
            table[key] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "pinned_area")
        }
        return table
    }

    static let groupItemPrefix = "itm_g_"
}
