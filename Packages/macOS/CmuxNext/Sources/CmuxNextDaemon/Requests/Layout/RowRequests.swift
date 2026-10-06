import Foundation

/// `new-row` (`rows-v1`): a row of `heightPermille` below `pane`'s row, in
/// its column, holding one new pane with one new terminal.
public struct NewRowRequest: TerminalSpawningRequest {
    public typealias Response = SurfaceCreated
    public static let command = "new-row"
    public var pane: PaneID
    /// 100...1000 permille of the column's viewport height.
    public var heightPermille: Int
    public var options: SpawnOptions
    public init(pane: PaneID, height: Int, options: SpawnOptions = SpawnOptions()) {
        self.pane = pane
        self.heightPermille = height
        self.options = options
    }
    enum CodingKeys: String, CodingKey { case pane, heightPermille }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        try c.encode(heightPermille, forKey: .heightPermille)
        try options.encode(to: encoder)
    }
}

/// `set-row-heights` (`rows-v1`): every row of one column at once. `fit`
/// requires a sum of exactly 1000.
public struct SetRowHeightsRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-row-heights"
    public var column: ColumnID
    public var heights: [RowHeightValue]
    public var fit: Bool
    public var transaction: UInt64?
    public init(column: ColumnID, heights: [RowHeightValue], fit: Bool = false, transaction: UInt64? = nil) {
        self.column = column
        self.heights = heights
        self.fit = fit
        self.transaction = transaction
    }
}
