import Foundation

/// Adds tabs to a group (moving them next to it, across panes if needed).
public struct AddTabsToGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "add-tabs-to-tab-group"
    public var group: TabGroupID
    public var tabs: [SurfaceID]
    /// Position inside the group; nil appends.
    public var index: Int?
    public var transaction: ClientTransactionID?

    public init(group: TabGroupID, tabs: [SurfaceID], index: Int? = nil, transaction: ClientTransactionID? = nil) {
        self.group = group
        self.tabs = tabs
        self.index = index
        self.transaction = transaction
    }
}

/// Removes tabs from whatever group holds them; they stay in the pane.
public struct RemoveTabsFromGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "remove-tabs-from-tab-group"
    public var tabs: [SurfaceID]
    public var transaction: ClientTransactionID?

    public init(tabs: [SurfaceID], transaction: ClientTransactionID? = nil) {
        self.tabs = tabs
        self.transaction = transaction
    }
}
