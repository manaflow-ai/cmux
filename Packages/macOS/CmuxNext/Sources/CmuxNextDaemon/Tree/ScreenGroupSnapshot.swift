import Foundation

/// `ScreenGroupSnapshot` itself is generated from the schema's `ScreenGroupRun` (swift_app/bindings.json, Tree family).
extension ScreenGroupSnapshot {
    /// Member count; the wire's `count` always equals `screens.count`.
    public var count: Int { screens.count }
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
    /// The group's icon (`screen-group-icon-v1`); nil is none.
    public var icon: String?
    /// Owning profile; nil = `default` (data-model.md 1).
    public var profileID: String?
    public var members: [Member]
    /// The live group linked to this record, if any.
    public var openGroup: ScreenGroupID?

    enum CodingKeys: String, CodingKey {
        case id, name, color, icon, members
        case profileID = "profile_id"
        case openGroup = "open_group"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SavedScreenGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        openGroup = try c.decodeIfPresent(ScreenGroupID.self, forKey: .openGroup)
    }
}
