import Foundation

// Screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

public struct SaveScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "save-screen-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenGroups
    public var group: ScreenGroupID
    public init(group: ScreenGroupID) { self.group = group }
}

public struct UnsaveScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "unsave-screen-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenGroups
    public var group: ScreenGroupID
    public init(group: ScreenGroupID) { self.group = group }
}

public struct ListSavedScreenGroupsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var groups: [SavedScreenGroupSnapshot]
    }
    public static let command = "list-saved-screen-groups"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenGroups
    public init() {}
}
