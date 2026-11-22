import Foundation

// Screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

public struct DeleteSavedScreenGroupRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "delete-saved-screen-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenGroups
    public var saved: SavedScreenGroupID
    public init(saved: SavedScreenGroupID) { self.saved = saved }
}

/// Reopens a saved group into `workspace` (or focuses it when already open).
public struct ReopenSavedScreenGroupRequest: DaemonRequest, TerminalSpawningRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "reopen-saved-screen-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenGroups
    public var saved: SavedScreenGroupID
    public var workspace: WorkspaceHandle
    public init(saved: SavedScreenGroupID, workspace: WorkspaceHandle) {
        self.saved = saved
        self.workspace = workspace
    }
}
