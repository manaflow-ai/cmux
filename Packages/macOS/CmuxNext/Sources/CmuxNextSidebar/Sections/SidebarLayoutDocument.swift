import Foundation

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
