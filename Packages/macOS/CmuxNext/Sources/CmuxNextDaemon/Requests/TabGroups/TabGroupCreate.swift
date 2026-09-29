import Foundation

/// Groups tabs of one pane. Members become contiguous at the first one's
/// position and leave any group they were in; pinned tabs are refused.
public struct CreateTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "create-tab-group"
    /// Tabs of one pane (wire `surfaces`).
    public var tabs: [SurfaceID]
    /// Caller-chosen id makes a retry idempotent; nil lets the daemon generate `tgrp_...`.
    public var group: TabGroupID?
    /// Default `""` (color only).
    public var name: String?
    /// One of the nine colors; default `grey`.
    public var color: String?
    public var transaction: ClientTransactionID?

    public init(tabs: [SurfaceID], group: TabGroupID? = nil, name: String? = nil, color: String? = nil,
                transaction: ClientTransactionID? = nil) {
        self.tabs = tabs
        self.group = group
        self.name = name
        self.color = color
        self.transaction = transaction
    }

    /// The daemon derives the pane from `tabs`; `pane` is not sent.
    @available(*, deprecated, message: "The daemon derives the pane from the tabs; use init(tabs:group:name:color:transaction:)")
    public init(pane: PaneID, tabs: [SurfaceID], group: TabGroupID? = nil, name: String? = nil, color: String? = nil,
                transaction: ClientTransactionID? = nil) {
        self.init(tabs: tabs, group: group, name: name, color: color, transaction: transaction)
    }

    enum CodingKeys: String, CodingKey { case surfaces, group, name, color, transaction }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tabs, forKey: .surfaces)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }
}

/// Rename, recolor, or collapse/expand; absent fields are unchanged. A linked
/// saved group follows. The daemon has no color clear: `.clear` sends
/// `null`, which it treats as unchanged.
public struct UpdateTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "update-tab-group"
    public var group: TabGroupID
    public var name: String?
    public var color: FieldUpdate<String>
    public var collapsed: Bool?

    public init(group: TabGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged, collapsed: Bool? = nil) {
        self.group = group
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }

    /// `update-tab-group` takes no transaction; `transaction` is ignored.
    @available(*, deprecated, message: "update-tab-group takes no transaction; use init(group:name:color:collapsed:)")
    public init(group: TabGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged, collapsed: Bool? = nil,
                transaction: ClientTransactionID?) {
        self.init(group: group, name: name, color: color, collapsed: collapsed)
    }

    enum CodingKeys: String, CodingKey { case group, name, color, collapsed }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(collapsed, forKey: .collapsed)
    }
}
