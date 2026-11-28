import Foundation

/// Drops a whole group between strip columns.
public struct MoveTabGroupToColumnRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "move-tab-group-to-column"
    public static let requiredCapability: String? = DaemonCapability.tabGroups.rawValue
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
