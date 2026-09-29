import Foundation

/// Deletes a group; its tabs stay in place. Result: `{group, surfaces}`.
public struct UngroupTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "ungroup-tab-group"
    public var group: TabGroupID
    public init(group: TabGroupID) { self.group = group }

    @available(*, deprecated, message: "ungroup-tab-group takes no transaction; use init(group:)")
    public init(group: TabGroupID, transaction: ClientTransactionID?) { self.init(group: group) }
}

/// Closes every member placement in one commit. Terminal processes keep
/// running, as with any closed view; a linked saved group remains.
/// Result: `{group, closed}`.
public struct CloseTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "close-tab-group"
    public var group: TabGroupID
    public init(group: TabGroupID) { self.group = group }

    @available(*, deprecated, message: "close-tab-group takes no transaction; use init(group:)")
    public init(group: TabGroupID, transaction: ClientTransactionID?) { self.init(group: group) }
}
