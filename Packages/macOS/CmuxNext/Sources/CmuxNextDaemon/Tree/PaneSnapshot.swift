import Foundation

public struct PaneSnapshot: Sendable, Hashable, Decodable {
    public var id: PaneID
    public var resourceID: ResourceID?
    public var shortID: String?
    public var name: String?
    /// Shared compatibility default, not user focus.
    public var activeTab: Int
    public var focusedAt: UInt64
    public var tabs: [TabSnapshot]
    /// Chrome-style groups in this strip, in strip order (`tab-groups-v1`).
    public var tabGroups: [TabGroupSnapshot]
    /// Serialized only when the tree references a pane missing from state.
    public var dead: Bool

    public init(
        id: PaneID,
        resourceID: ResourceID? = nil,
        shortID: String? = nil,
        name: String? = nil,
        activeTab: Int = 0,
        focusedAt: UInt64 = 0,
        tabs: [TabSnapshot] = [],
        tabGroups: [TabGroupSnapshot] = [],
        dead: Bool = false
    ) {
        self.id = id
        self.resourceID = resourceID
        self.shortID = shortID
        self.name = name
        self.activeTab = activeTab
        self.focusedAt = focusedAt
        self.tabs = tabs
        self.tabGroups = tabGroups
        self.dead = dead
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tabs, dead
        case resourceID = "resource_id"
        case shortID = "short_id"
        case activeTab = "active_tab"
        case focusedAt = "focused_at"
        case tabGroups = "tab_groups"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        resourceID = try c.decodeIfPresent(ResourceID.self, forKey: .resourceID)
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        activeTab = try c.decodeIfPresent(Int.self, forKey: .activeTab) ?? 0
        focusedAt = try c.decodeIfPresent(UInt64.self, forKey: .focusedAt) ?? 0
        tabs = try c.decodeIfPresent([TabSnapshot].self, forKey: .tabs) ?? []
        tabGroups = try c.decodeIfPresent([TabGroupSnapshot].self, forKey: .tabGroups) ?? []
        dead = try c.decodeIfPresent(Bool.self, forKey: .dead) ?? false
    }
}
