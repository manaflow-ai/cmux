import Foundation

// Screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

/// Moves a whole group to `index` (the final index of its first screen), or
/// into `workspace`.
public struct MoveScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "move-screen-group"
    public static let requiredCapability: String? = DaemonCapability.screenGroups.rawValue
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
