import Foundation

// Chrome-style tab groups (plans/cmux-next/REWRITE.md "Groups").
// TODO(feat-cmux-next-daemon): proposed commands, capability `tab-groups-v1`;
// wire names follow the tab-drag-v1 conventions (`transaction` echo,
// `move-*-to-split/column/new-workspace`) and are guesses until that branch
// serves them. Current daemons reject them with "unknown variant", which the
// convenience API maps to `DaemonError.missingCapabilities`.

/// Result of a tab-group command: the group after the change plus any
/// placement the command created.
public struct TabGroupResult: Decodable, Sendable, Equatable {
    public var group: TabGroupSnapshot?
    public var pane: PaneID?
    public var screen: ScreenID?
    public var workspace: WorkspaceHandle?
    public var key: WorkspaceKey?
    public var changed: Bool?
    public var undoable: Bool?
}

/// Groups `tabs` (all in `pane`) under a new group.
public struct CreateTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "create-tab-group"
    public var pane: PaneID
    public var tabs: [SurfaceID]
    /// Caller-chosen id makes a retry idempotent.
    public var group: TabGroupID?
    public var name: String?
    public var color: String?
    public var transaction: ClientTransactionID?

    public init(pane: PaneID, tabs: [SurfaceID], group: TabGroupID? = nil, name: String? = nil, color: String? = nil,
                transaction: ClientTransactionID? = nil) {
        self.pane = pane
        self.tabs = tabs
        self.group = group
        self.name = name
        self.color = color
        self.transaction = transaction
    }
}

/// Rename, recolor (null clears), or collapse/expand.
public struct UpdateTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "update-tab-group"
    public var group: TabGroupID
    public var name: String?
    public var color: FieldUpdate<String>
    public var collapsed: Bool?
    public var transaction: ClientTransactionID?

    public init(group: TabGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged, collapsed: Bool? = nil,
                transaction: ClientTransactionID? = nil) {
        self.group = group
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.transaction = transaction
    }

    enum CodingKeys: String, CodingKey { case group, name, color, collapsed, transaction }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(collapsed, forKey: .collapsed)
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }
}
