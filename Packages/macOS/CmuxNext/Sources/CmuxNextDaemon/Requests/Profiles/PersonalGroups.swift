import Foundation

// Personal workspace groups and per-workspace organization (`profiles-v1`,
// home session only). Group JSON is the workspace group shape plus `profile`.

public struct PersonalGroupResult: Decodable, Sendable, Equatable {
    public var group: WorkspaceGroupSnapshot
    public var changed: Bool
}

public struct UpdatePersonalGroupRequest: DaemonRequest {
    public typealias Response = PersonalGroupResult
    public static let command = "update-personal-group"
    public static let requiredCapability: String? = DaemonCapability.profiles.rawValue
    public var group: WorkspaceGroupID
    public var name: String?
    public var color: FieldUpdate<String>
    public var collapsed: Bool?
    /// Moves the group, and pins its members, to another room.
    public var profile: ProfileID?
    public init(group: WorkspaceGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged, collapsed: Bool? = nil,
                profile: ProfileID? = nil) {
        self.group = group
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey { case group, name, color, collapsed, profile }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(collapsed, forKey: .collapsed)
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}
