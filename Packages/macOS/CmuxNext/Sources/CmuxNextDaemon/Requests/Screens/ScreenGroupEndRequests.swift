import Foundation

// Screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

public struct UngroupScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "ungroup-screen-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenGroups
    public var group: ScreenGroupID
    public init(group: ScreenGroupID) { self.group = group }
}

/// Closes every member screen. A saved group keeps its saved record.
public struct CloseScreenGroupRequest: DaemonRequest {
    public typealias Response = ScreenGroupResult
    public static let command = "close-screen-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenGroups
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
