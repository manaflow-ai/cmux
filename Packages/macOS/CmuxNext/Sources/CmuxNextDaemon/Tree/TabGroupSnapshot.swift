import Foundation

/// Chrome-style tab group inside one pane's strip: named, colored, and
/// collapsible; tabs join and leave it, and it moves as a unit.
///
/// TODO(feat-cmux-next-daemon): proposed shape `Pane.tab_groups[]` of
/// `{id, name, color, collapsed, tabs}` plus `Tab.tab_group`, capability
/// `tab-groups-v1` (plans/cmux-next/REWRITE.md "Groups"). Wire names are
/// guesses until that branch serves them; absent fields decode as empty.
public struct TabGroupSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: TabGroupID
    public var name: String
    /// Palette token or `#RRGGBB[AA]`.
    public var color: String?
    public var collapsed: Bool
    /// Member tabs in strip order.
    public var tabs: [TabGroupMember]

    public init(id: TabGroupID, name: String = "", color: String? = nil, collapsed: Bool = false, tabs: [TabGroupMember] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.tabs = tabs
    }

    enum CodingKeys: String, CodingKey { case id, name, color, collapsed, tabs }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TabGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        tabs = try c.decodeIfPresent([TabGroupMember].self, forKey: .tabs) ?? []
    }
}

/// A group member, named by numeric surface or durable tab resource id,
/// whichever the daemon serializes.
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
