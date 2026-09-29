import Foundation

/// Splits a pane with a new terminal (`cwd`/`env` with `terminal-env-v1`).
/// The daemon's `split` has no `tab` field; moving an existing tab into a new
/// pane is `move-tab-to-split` (`DaemonConnection.split(_:direction:movingTab:)`
/// routes there). `tab` is not sent.
public struct SplitRequest: DaemonRequest {
    public typealias Response = SurfaceCreated
    public static let command = "split"
    public var pane: PaneID
    public var direction: SplitDirection
    public var tab: SurfaceID?
    public var options: SpawnOptions
    public init(pane: PaneID, direction: SplitDirection, tab: SurfaceID? = nil, options: SpawnOptions = SpawnOptions()) {
        self.pane = pane
        self.direction = direction
        self.tab = tab
        self.options = options
    }
    enum CodingKeys: String, CodingKey { case pane, dir }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        try c.encode(direction, forKey: .dir)
        try options.encode(to: encoder)
    }
}

/// Adds a pane to the pane's column (vertical stack inside a column).
public struct NewPaneRequest: DaemonRequest {
    public typealias Response = SurfaceCreated
    public static let command = "new-pane"
    public var pane: PaneID
    public var options: SpawnOptions
    public init(pane: PaneID, options: SpawnOptions = SpawnOptions()) {
        self.pane = pane
        self.options = options
    }
    enum CodingKeys: String, CodingKey { case pane }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        try options.encode(to: encoder)
    }
}

/// Adds a new scrolling column to the right (`viewport-splits-v1`).
public struct NewColumnRequest: DaemonRequest {
    public typealias Response = SurfaceCreated
    public static let command = "new-pane-right"
    public var pane: PaneID
    /// Fraction of the viewport, 0.1...1.0. Daemon default 2/3.
    public var width: Double?
    public var options: SpawnOptions
    public init(pane: PaneID, width: Double? = nil, options: SpawnOptions = SpawnOptions()) {
        self.pane = pane
        self.width = width
        self.options = options
    }
    enum CodingKeys: String, CodingKey { case pane, width }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        try c.encodeIfPresent(width, forKey: .width)
        try options.encode(to: encoder)
    }
}
