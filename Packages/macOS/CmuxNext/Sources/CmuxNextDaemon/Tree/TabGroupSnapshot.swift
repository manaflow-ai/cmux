import Foundation

/// A tab group inside one pane's strip (`tab-groups-v1`): named,
/// colored, collapsible, members contiguous. Wire shape `Pane.tab_groups[]`:
/// `{id, name, color, collapsed, saved_id, start, count, surfaces}`. Command
/// results carry the same object without the run fields.
public struct TabGroupSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: TabGroupID
    public var name: String
    /// One of the nine group colors (`grey`, `blue`, `red`, `yellow`, `green`, `pink`,
    /// `purple`, `cyan`, `orange`).
    public var color: String?
    public var collapsed: Bool
    /// The saved record this live group is linked to (`saved-tab-groups-v1`).
    public var savedID: SavedTabGroupID?
    /// Strip index of the first member.
    public var start: Int
    public var count: Int
    /// Member tabs in strip order.
    public var surfaces: [SurfaceID]
    /// The pane, in `list-tab-groups` rows only.
    public var pane: PaneID?

    /// Members as `TabGroupMember`s (the pre-15518 shape).
    public var tabs: [TabGroupMember] { surfaces.map(TabGroupMember.surface) }

    public init(id: TabGroupID, name: String = "", color: String? = nil, collapsed: Bool = false, savedID: SavedTabGroupID? = nil,
                start: Int = 0, surfaces: [SurfaceID] = [], pane: PaneID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.savedID = savedID
        self.start = start
        self.count = surfaces.count
        self.surfaces = surfaces
        self.pane = pane
    }

    @available(*, deprecated, message: "Use init(id:name:color:collapsed:savedID:start:surfaces:pane:)")
    public init(id: TabGroupID, name: String = "", color: String? = nil, collapsed: Bool = false, tabs: [TabGroupMember]) {
        self.init(id: id, name: name, color: color, collapsed: collapsed, surfaces: tabs.compactMap {
            if case .surface(let surface) = $0 { surface } else { nil }
        })
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, collapsed, start, count, surfaces, pane
        case savedID = "saved_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TabGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        savedID = try c.decodeIfPresent(SavedTabGroupID.self, forKey: .savedID)
        surfaces = try c.decodeIfPresent([SurfaceID].self, forKey: .surfaces) ?? []
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? surfaces.count
        pane = try c.decodeIfPresent(PaneID.self, forKey: .pane)
    }
}

/// A group member, named by numeric surface or durable tab resource id.
public enum TabGroupMember: Sendable, Hashable, Decodable {
    case surface(SurfaceID)
    case tab(ResourceID)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let surface = try? container.decode(UInt64.self) {
            self = .surface(SurfaceID(rawValue: surface))
        } else {
            self = .tab(ResourceID(rawValue: try container.decode(String.self)))
        }
    }

    /// True when this member names `tab`.
    public func matches(_ tab: TabSnapshot) -> Bool {
        switch self {
        case .surface(let surface): surface == tab.surface
        case .tab(let resource): resource == tab.tabResourceID
        }
    }
}
