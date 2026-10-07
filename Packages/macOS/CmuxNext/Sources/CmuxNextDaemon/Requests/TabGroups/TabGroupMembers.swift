import Foundation

/// Adds tabs at the end of a group's run. Tabs in other panes, screens, or
/// workspaces move into the group's pane in the same commit.
public struct AddTabsToGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "add-tabs-to-tab-group"
    public var group: TabGroupID
    /// Wire `surfaces`.
    public var tabs: [SurfaceID]
    public var transaction: ClientTransactionID?

    public init(group: TabGroupID, tabs: [SurfaceID], transaction: ClientTransactionID? = nil) {
        self.group = group
        self.tabs = tabs
        self.transaction = transaction
    }

    /// The daemon always appends; `index` is not sent. Use
    /// `DaemonConnection.addTabs(_:toGroup:index:transaction:)`, which
    /// follows up with `move-tab` for an in-group position.
    @available(*, deprecated, message: "add-tabs-to-tab-group always appends; use DaemonConnection.addTabs(_:toGroup:index:transaction:)")
    public init(group: TabGroupID, tabs: [SurfaceID], index: Int?, transaction: ClientTransactionID? = nil) {
        self.init(group: group, tabs: tabs, transaction: transaction)
    }

    enum CodingKeys: String, CodingKey { case group, surfaces, transaction }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
        try c.encode(tabs, forKey: .surfaces)
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }
}

/// Removes tabs from their groups; each lands just after its former group.
/// A group left without members disappears.
public struct RemoveTabsFromGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "remove-tabs-from-tab-group"
    /// Wire `surfaces`.
    public var tabs: [SurfaceID]
    public var transaction: ClientTransactionID?

    public init(tabs: [SurfaceID], transaction: ClientTransactionID? = nil) {
        self.tabs = tabs
        self.transaction = transaction
    }

    enum CodingKeys: String, CodingKey { case surfaces, transaction }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tabs, forKey: .surfaces)
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }
}
