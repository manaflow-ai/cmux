import Foundation

// Screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

public struct ListSavedScreenGroupsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var groups: [SavedScreenGroupSnapshot]
    }
    public static let command = "list-saved-screen-groups"
    public static let requiredCapability: String? = DaemonCapability.screenGroups.rawValue
    public init() {}
}
