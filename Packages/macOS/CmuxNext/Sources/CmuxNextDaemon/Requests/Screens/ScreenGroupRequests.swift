import Foundation

// Chrome-style screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

/// Result of a screen group command. `group` is the group after the change
/// (nil when the command returns only its id or the group is gone).
public struct ScreenGroupResult: Decodable, Sendable, Equatable {
    public var group: ScreenGroupSnapshot?
    public var groupID: ScreenGroupID?
    public var workspace: WorkspaceHandle?
    public var screens: [ScreenID]
    /// `close-screen-group`: the closed screens.
    public var closed: [ScreenID]

    enum CodingKeys: String, CodingKey { case group, workspace, screens, closed }

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

/// Adds screens to a group. `index` is the position inside the group (default: the end).
public struct AddScreensToScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "add-screens-to-screen-group"
    public var group: ScreenGroupID
    public var screens: [ScreenID]
    public var index: Int?
    public init(group: ScreenGroupID, screens: [ScreenID], index: Int? = nil) {
        self.group = group
        self.screens = screens
        self.index = index
    }
}

/// Removes screens from their groups; each lands right after its former group.
public struct RemoveScreensFromScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "remove-screens-from-screen-group"
    public var screens: [ScreenID]
    public init(screens: [ScreenID]) { self.screens = screens }
}

/// Moves a whole group to `index` (the final index of its first screen), or
/// into `workspace`.
public struct MoveScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "move-screen-group"
    public var group: ScreenGroupID
    public var index: Int?
    public var workspace: WorkspaceHandle?
    public init(group: ScreenGroupID, index: Int? = nil, workspace: WorkspaceHandle? = nil) {
        self.group = group
        self.index = index
        self.workspace = workspace
    }
}

public struct UngroupScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "ungroup-screen-group"
    public var group: ScreenGroupID
    public init(group: ScreenGroupID) { self.group = group }
}

/// Closes every member screen. A saved group keeps its saved record.
public struct CloseScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "close-screen-group"
    public var group: ScreenGroupID
    public var endTerminals: Bool?
    public init(group: ScreenGroupID, endTerminals: Bool? = nil) {
        self.group = group
        self.endTerminals = endTerminals
    }
    enum CodingKeys: String, CodingKey {
        case group
        case endTerminals = "end_terminals"
    }
}

public struct SaveScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "save-screen-group"
    public var group: ScreenGroupID
    public init(group: ScreenGroupID) { self.group = group }
}

public struct UnsaveScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "unsave-screen-group"
    public var group: ScreenGroupID
    public init(group: ScreenGroupID) { self.group = group }
}

public struct ListSavedScreenGroupsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var groups: [SavedScreenGroupSnapshot]
    }
    public static let command = "list-saved-screen-groups"
    public init() {}
}

public struct DeleteSavedScreenGroupRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "delete-saved-screen-group"
    public var saved: SavedScreenGroupID
    public init(saved: SavedScreenGroupID) { self.saved = saved }
}

/// Reopens a saved group into `workspace` (or focuses it when already open).
public struct ReopenSavedScreenGroupRequest: DaemonRequest, TerminalSpawningRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "reopen-saved-screen-group"
    public var saved: SavedScreenGroupID
    public var workspace: WorkspaceHandle
    public init(saved: SavedScreenGroupID, workspace: WorkspaceHandle) {
        self.saved = saved
        self.workspace = workspace
    }
}
