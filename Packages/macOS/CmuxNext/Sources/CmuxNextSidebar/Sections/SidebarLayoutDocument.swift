import Foundation

// The sidebar's section layout (plans/cmux-next/sidebar-sections.md 4):
// an ordered list of sections in three regions. The workspace store owns
// the document (`sidebar-layout-v1`); clients render it and send
// `SidebarLayoutOp`s. Field names match the wire (snake_case).

/// Where a section sits: sticky at the top, in the scrolling middle, or
/// sticky at the bottom.
public nonisolated enum SidebarRegion: String, Hashable, Sendable, Codable, CaseIterable {
    case top
    case middle
    case bottom
}

/// How a section's rows look: `builtIn` rows read as app chrome (Home);
/// `list` rows look like workspace rows.
public nonisolated enum SectionLook: String, Hashable, Sendable, Codable, CaseIterable {
    case builtIn = "built_in"
    case list
}

/// What a section holds: its own items, or the workspace list (exactly
/// one section, invariant L1).
public nonisolated enum SectionContent: String, Hashable, Sendable, Codable {
    case items
    case workspaces
}

/// Stable id of a section (`sec_…`), minted by the client that adds it.
public nonisolated struct LayoutSectionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
    /// A new random id.
    public static func mint() -> LayoutSectionID { LayoutSectionID("sec_" + LayoutIDs.random()) }
}

/// Stable id of an item (`itm_…`); it survives moves between sections.
public nonisolated struct LayoutItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func mint() -> LayoutItemID { LayoutItemID("itm_" + LayoutIDs.random()) }
}

nonisolated enum LayoutIDs {
    /// 16 lowercase base32 characters (80 bits).
    static func random() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var generator = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int(generator.next(upperBound: UInt32(alphabet.count)))] })
    }
}

/// Destinations defined in code. Each is a launcher for a registry action
/// (the App maps them); the sidebar only knows the symbol and title.
public nonisolated enum SidebarBuiltIn: String, Hashable, Sendable, CaseIterable {
    case home
    case settings
    case account
    case notifications
    case history
    case bookmarks
}

/// What an item points at: a kind and a string value. Kinds this client
/// does not know are kept verbatim (L5).
public nonisolated struct LayoutItemRef: Hashable, Sendable, Codable {
    public var kind: String
    public var value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }

    public static let builtInKind = "built_in"
    public static let workspaceKind = "workspace"
    public static let tabKind = "tab"
    public static let roomKind = "room"
    public static let savedGroupKind = "saved_group"
    public static let urlKind = "url"

    public static func builtIn(_ item: SidebarBuiltIn) -> LayoutItemRef { LayoutItemRef(kind: builtInKind, value: item.rawValue) }
    /// A qualified public workspace id (`<session>:ws_…`).
    public static func workspace(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: workspaceKind, value: id) }
    /// A qualified public tab id (`<session>:tab_…`).
    public static func tab(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: tabKind, value: id) }
    public static func room(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: roomKind, value: id) }
    public static func savedGroup(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: savedGroupKind, value: id) }
    public static func url(_ url: String) -> LayoutItemRef { LayoutItemRef(kind: urlKind, value: url) }

    /// The built-in this ref names, or nil (another kind, or a built-in
    /// from a newer client).
    public var builtIn: SidebarBuiltIn? { kind == Self.builtInKind ? SidebarBuiltIn(rawValue: value) : nil }
}

public nonisolated struct LayoutItem: Hashable, Sendable, Codable, Identifiable {
    public var id: LayoutItemID
    public var ref: LayoutItemRef

    public init(id: LayoutItemID, ref: LayoutItemRef) {
        self.id = id
        self.ref = ref
    }
}

/// One section of the layout.
public nonisolated struct LayoutSection: Hashable, Sendable, Codable, Identifiable {
    public var id: LayoutSectionID
    /// Header text; nil draws no header (and the section cannot collapse).
    public var title: String?
    public var region: SidebarRegion
    public var look: SectionLook
    /// The room this section shows in; nil = every room.
    public var room: String?
    /// Rows a sticky section shows before it scrolls inside; nil = the
    /// region's share of the sidebar height.
    public var maxRows: Int?
    public var content: SectionContent
    /// Empty for the workspaces section.
    public var items: [LayoutItem]

    public init(id: LayoutSectionID, title: String? = nil, region: SidebarRegion, look: SectionLook = .list,
                room: String? = nil, maxRows: Int? = nil, content: SectionContent = .items, items: [LayoutItem] = []) {
        self.id = id
        self.title = title
        self.region = region
        self.look = look
        self.room = room
        self.maxRows = maxRows
        self.content = content
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, title, region, look, room, content, items
        case maxRows = "max_rows"
    }

    /// Whether the section shows while `room` is shown.
    public func isVisible(inRoom room: String?) -> Bool { self.room == nil || self.room == room }
}

/// The whole layout.
public nonisolated struct SidebarLayoutDocument: Hashable, Sendable, Codable {
    /// Increases by one per committed change.
    public var revision: UInt64
    public var sections: [LayoutSection]

    public init(revision: UInt64 = 0, sections: [LayoutSection]) {
        self.revision = revision
        self.sections = sections
    }

    /// Fixed ids, so a never-written layout is identical on every device.
    public static let topSectionID = LayoutSectionID("sec_top")
    public static let workspacesSectionID = LayoutSectionID("sec_workspaces")
    public static let bottomSectionID = LayoutSectionID("sec_bottom")

    /// Top: Home. Middle: workspaces. Bottom: Settings and Account. Sticky
    /// sections use the built-in look and draw no header.
    public static let defaults = SidebarLayoutDocument(sections: [
        LayoutSection(id: topSectionID, region: .top, look: .builtIn,
                      items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home))]),
        LayoutSection(id: workspacesSectionID, region: .middle, look: .list, content: .workspaces),
        LayoutSection(id: bottomSectionID, region: .bottom, look: .builtIn, items: [
            LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings)),
            LayoutItem(id: LayoutItemID("itm_account"), ref: .builtIn(.account)),
        ]),
    ])

    /// Sections of `region` that show in `room`, in order.
    public func sections(in region: SidebarRegion, room: String?) -> [LayoutSection] {
        sections.filter { $0.region == region && $0.isVisible(inRoom: room) }
    }

    public func section(_ id: LayoutSectionID) -> LayoutSection? { sections.first { $0.id == id } }

    /// Section index and item index of `id`.
    public func locate(_ id: LayoutItemID) -> (section: Int, item: Int)? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.id == id }) { return (s, i) }
        }
        return nil
    }

    public func item(_ id: LayoutItemID) -> LayoutItem? { locate(id).map { sections[$0.section].items[$0.item] } }

    /// The first item with `ref`, in document order.
    public func firstItem(with ref: LayoutItemRef) -> LayoutItem? {
        for section in sections { if let item = section.items.first(where: { $0.ref == ref }) { return item } }
        return nil
    }

    /// The first item of the first top-region section shown in `room`
    /// (what Cmd-1 runs), or nil when the top region is empty.
    public func firstTopItem(room: String?) -> LayoutItem? {
        sections(in: .top, room: room).lazy.compactMap(\.items.first).first
    }
}
