import Foundation

/// Dissolves a group; its tabs stay where they are.
public struct UngroupTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "ungroup-tab-group"
    public var group: TabGroupID
    public var transaction: ClientTransactionID?
    public init(group: TabGroupID, transaction: ClientTransactionID? = nil) {
        self.group = group
        self.transaction = transaction
    }
}

/// Closes a group and every tab in it (views only; PTYs follow the daemon's
/// normal close rules).
public struct CloseTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "close-tab-group"
    public var group: TabGroupID
    public var transaction: ClientTransactionID?
    public init(group: TabGroupID, transaction: ClientTransactionID? = nil) {
        self.group = group
        self.transaction = transaction
    }
}
