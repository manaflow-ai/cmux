import Foundation

// split, new-pane and new-tab are generated (swift_app bindings.json, Creation); new-pane-right stays hand-written:
// the schema gates it on viewport-splits-v1, which the app does not check before sending.

/// Adds a new scrolling column to the right (`viewport-splits-v1`).
public struct NewColumnRequest: TerminalSpawningRequest {
    public typealias Response = SurfaceCreated
    public static let command = "new-pane-right"
    public var pane: PaneID
    /// Fraction of the viewport, 0.1...1.0. Daemon default 2/3.
    public var width: Double?
    /// Opens the column before the pane's column (`side: "left"`, `column-left-v1`, New Column
    /// Left) instead of after it. Sent only when true, so older daemons see the same request.
    public var left: Bool
    public var options: SpawnOptions
    public init(pane: PaneID, width: Double? = nil, left: Bool = false, options: SpawnOptions = SpawnOptions()) {
        self.pane = pane
        self.width = width
        self.left = left
        self.options = options
    }
    enum CodingKeys: String, CodingKey { case pane, width, side }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        try c.encodeIfPresent(width, forKey: .width)
        if left { try c.encode("left", forKey: .side) }
        try options.encode(to: encoder)
    }
}
