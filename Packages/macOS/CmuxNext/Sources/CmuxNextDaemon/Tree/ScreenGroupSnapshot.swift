import Foundation

/// Chrome-style group of screens inside one workspace (`screen-groups-v1`):
/// named, colored, collapsible, members contiguous in screen order. Wire
/// shape `Workspace.screen_groups[]`: `{id, name, color, collapsed,
/// saved_id, start, count, screens}`.
public struct ScreenGroupSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: ScreenGroupID
    public var name: String
    /// One of the nine group colors.
    public var color: String?
    public var collapsed: Bool
    /// The saved record this live group is linked to.
    public var savedID: SavedScreenGroupID?
    /// Index of the first member in the workspace's screen list.
    public var start: Int
    public var count: Int
    /// Member screens in order.
    public var screens: [ScreenID]

    public init(id: ScreenGroupID, name: String = "", color: String? = nil, collapsed: Bool = false,
                savedID: SavedScreenGroupID? = nil, start: Int = 0, screens: [ScreenID] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.savedID = savedID
        self.start = start
        self.count = screens.count
        self.screens = screens
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, collapsed, start, count, screens
        case savedID = "saved_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ScreenGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        savedID = try c.decodeIfPresent(SavedScreenGroupID.self, forKey: .savedID)
        screens = try c.decodeIfPresent([ScreenID].self, forKey: .screens) ?? []
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? screens.count
    }
}

/// A saved screen group (`list-saved-screen-groups`): a session-wide record
/// that outlives its screens. Reopening creates one screen per member with a
/// terminal in the member's saved directory, or reattaches the member's
/// terminal when it still runs.
public struct SavedScreenGroupSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public struct Member: Sendable, Hashable, Decodable {
        public var name: String?
        public var color: String?
        public var icon: String?
        public var cwd: String?
    }

    public var id: SavedScreenGroupID
    public var name: String
    public var color: String?
    /// Owning profile; nil = `default` (data-model.md 1).
    public var profileID: String?
    public var members: [Member]
    /// The live group linked to this record, if any.
    public var openGroup: ScreenGroupID?

    enum CodingKeys: String, CodingKey {
        case id, name, color, members
        case profileID = "profile_id"
        case openGroup = "open_group"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SavedScreenGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        openGroup = try c.decodeIfPresent(ScreenGroupID.self, forKey: .openGroup)
    }
}
