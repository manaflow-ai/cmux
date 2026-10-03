import Foundation

/// Reorders a group in its strip or moves it into another pane at `index`.
public struct MoveTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "move-tab-group"
    public var group: TabGroupID
    public var pane: PaneID
    public var index: Int
    public var transaction: ClientTransactionID?
    public init(group: TabGroupID, pane: PaneID, index: Int, transaction: ClientTransactionID? = nil) {
        self.group = group
        self.pane = pane
        self.index = index
        self.transaction = transaction
    }
}

/// Drops a whole group on a pane edge.
public struct MoveTabGroupToSplitRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "move-tab-group-to-split"
    public var group: TabGroupID
    public var pane: PaneID
    public var edge: PaneEdge
    public var ratio: Double?
    public var transaction: ClientTransactionID?
    public init(group: TabGroupID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil, transaction: ClientTransactionID? = nil) {
        self.group = group
        self.pane = pane
        self.edge = edge
        self.ratio = ratio
        self.transaction = transaction
    }
}

/// Drops a whole group between strip columns.
public struct MoveTabGroupToColumnRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "move-tab-group-to-column"
    public var group: TabGroupID
    public var target: ColumnDropTarget
    public var afterColumn: ColumnID?
    public var width: Double?
    public var transaction: ClientTransactionID?
    public init(group: TabGroupID, target: ColumnDropTarget, afterColumn: ColumnID? = nil, width: Double? = nil,
                transaction: ClientTransactionID? = nil) {
        self.group = group
        self.target = target
        self.afterColumn = afterColumn
        self.width = width
        self.transaction = transaction
    }

    enum CodingKeys: String, CodingKey { case group, pane, screen, afterColumn, width, transaction }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
        switch target {
        case .screen(let screen): try c.encode(screen, forKey: .screen)
        case .pane(let pane): try c.encode(pane, forKey: .pane)
        }
        try c.encodeIfPresent(afterColumn, forKey: .afterColumn)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }
}
