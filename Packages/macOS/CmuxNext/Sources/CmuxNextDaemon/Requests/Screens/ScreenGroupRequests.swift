import Foundation

// Screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

/// Result of a screen group command. `group` is the group after the change
/// (nil when the command returns only its id or the group is gone).
public struct ScreenGroupResult: Decodable, Sendable, Equatable {
    public var group: ScreenGroupSnapshot?
    public var groupID: ScreenGroupID?
    public var workspace: WorkspaceHandle?
    /// The workspace's durable key (moves into a new workspace).
    public var key: WorkspaceKey?
    public var screens: [ScreenID]
    /// `close-screen-group`: the closed screens.
    public var closed: [ScreenID]

    enum CodingKeys: String, CodingKey { case group, workspace, key, screens, closed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(ScreenGroupID.self, forKey: .group) {
            group = nil
            groupID = id
        } else {
            group = try c.decodeIfPresent(ScreenGroupSnapshot.self, forKey: .group)
            groupID = group?.id
        }
        workspace = try c.decodeIfPresent(WorkspaceHandle.self, forKey: .workspace)
        key = try c.decodeIfPresent(WorkspaceKey.self, forKey: .key)
        screens = try c.decodeIfPresent([ScreenID].self, forKey: .screens) ?? []
        closed = try c.decodeIfPresent([ScreenID].self, forKey: .closed) ?? []
    }
}

public struct CreateScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "create-screen-group"
    public var screens: [ScreenID]
    public var name: String?
    public var color: String?
    public init(screens: [ScreenID], name: String? = nil, color: String? = nil) {
        self.screens = screens
        self.name = name
        self.color = color
    }
}

public struct UpdateScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "update-screen-group"
    public var group: ScreenGroupID
    public var name: String?
    public var color: String?
    public var collapsed: Bool?
    public init(group: ScreenGroupID, name: String? = nil, color: String? = nil, collapsed: Bool? = nil) {
        self.group = group
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }
}
