import Foundation

/// One section of the layout.
public nonisolated struct LayoutSection: Hashable, Sendable, Codable, Identifiable {
    public var id: LayoutSectionID
    /// The section's name (palette, CLI, header). Nil: unnamed.
    public var title: String?
    /// Whether the header draws the title. False keeps the name for the
    /// palette and the CLI but draws no header (the section cannot then
    /// collapse). Looks without labels hide every header regardless.
    public var showsTitle: Bool
    public var region: SidebarRegion
    public var look: SectionLook
    /// Rows, one line, or a grid.
    public var arrangement: SectionArrangement
    /// The room this section shows in; nil = every room.
    public var room: String?
    /// Rows a sticky section shows before it scrolls inside; nil = the
    /// region's share of the sidebar height.
    public var maxRows: Int?
    public var content: SectionContent
    /// The app section this is (`<app id>#<section id>`), content `app` only.
    public var contribution: String?
    /// Empty for the workspaces section.
    public var items: [LayoutItem]

    public init(id: LayoutSectionID, title: String? = nil, showsTitle: Bool = true, region: SidebarRegion, look: SectionLook = .list,
                arrangement: SectionArrangement = .list, room: String? = nil, maxRows: Int? = nil, content: SectionContent = .items, contribution: String? = nil,
                items: [LayoutItem] = []) {
        self.contribution = contribution
        self.id = id
        self.title = title
        self.showsTitle = showsTitle
        self.region = region
        self.look = look
        self.arrangement = arrangement
        self.room = room
        self.maxRows = maxRows
        self.content = content
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, title, region, look, arrangement, room, content, contribution, items
        case showsTitle = "shows_title"
        case maxRows = "max_rows"
    }

    // Optional keys may be absent on the wire (defaults: shows_title true,
    // no items).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LayoutSectionID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        showsTitle = try c.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        region = try c.decode(SidebarRegion.self, forKey: .region)
        look = try c.decode(SectionLook.self, forKey: .look)
        arrangement = try c.decodeIfPresent(SectionArrangement.self, forKey: .arrangement) ?? .list
        room = try c.decodeIfPresent(String.self, forKey: .room)
        maxRows = try c.decodeIfPresent(Int.self, forKey: .maxRows)
        content = try c.decode(SectionContent.self, forKey: .content)
        contribution = try c.decodeIfPresent(String.self, forKey: .contribution)
        items = try c.decodeIfPresent([LayoutItem].self, forKey: .items) ?? []
    }

    /// The header title to draw, or nil for no header.
    public var headerTitle: String? { showsTitle ? title : nil }

    /// The app that owns this section: the id before `#` of an app
    /// section's contribution, else nil.
    public var owningAppID: String? {
        guard content == .app, let contribution, let hash = contribution.firstIndex(of: "#") else { return nil }
        let id = String(contribution[..<hash])
        return id.isEmpty ? nil : id
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

    /// Top: Home, then the App Store. Middle: workspaces. Bottom: one line with Settings (icon
    /// and label) at the leading edge, and Customize Appearance and the
    /// account avatar (icons only) at the trailing edge. Sticky sections use
    /// the built-in look and draw no header.
    public static let defaults = SidebarLayoutDocument(sections: [
        LayoutSection(id: topSectionID, region: .top, look: .builtIn,
                      items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home)),
                              LayoutItem(id: LayoutItemID("itm_app_store"), ref: .builtIn(.appStore))]),
        LayoutSection(id: workspacesSectionID, region: .middle, look: .list, content: .workspaces),
        LayoutSection(id: bottomSectionID, region: .bottom, look: .builtIn, arrangement: SectionArrangement(layout: .inline, align: .fill), items: [
            LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings)),
            LayoutItem(id: LayoutItemID("itm_customize"), ref: .builtIn(.customize), showsLabel: false),
            LayoutItem(id: LayoutItemID("itm_account"), ref: .builtIn(.account), showsLabel: false),
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
