import Foundation

// Chrome-style screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

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
    /// Moves the group into a new workspace created in the same commit.
    public var newWorkspace: Bool?
    public init(group: ScreenGroupID, index: Int? = nil, workspace: WorkspaceHandle? = nil, newWorkspace: Bool? = nil) {
        self.group = group
        self.index = index
        self.workspace = workspace
        self.newWorkspace = newWorkspace
    }
    enum CodingKeys: String, CodingKey {
        case group, index, workspace
        case newWorkspace = "new_workspace"
    }
}
