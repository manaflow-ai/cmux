import Foundation

/// `new-row` (`rows-v1`): a row of `heightPermille` below `pane`'s row, in
/// its column, holding one new pane with one new terminal.
public struct NewRowRequest: TerminalSpawningRequest {
    public typealias Response = SurfaceCreated
    public static let command = "new-row"
    public static let requiredCapability: String? = DaemonCapability.rows.rawValue
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
