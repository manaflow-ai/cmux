import Foundation

#if DEBUG
/// A context menu or `<select>` popup (`Menu`).
public nonisolated struct RbMenu: Sendable, Equatable, Decodable {
    /// `context` or `select`.
    public var kind: String
    /// Where the menu opens, in the surface's CSS pixels.
    public var anchor: RbRect
    public var surface: UInt32
    public var items: [RbMenuItem]
    public var selected: UInt32?
    public var multiple: Bool

    private enum CodingKeys: String, CodingKey { case kind, anchor, surface, items, selected, multiple }
}

public nonisolated struct RbRect: Sendable, Equatable, Decodable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

/// One menu entry (`MenuItem`).
public nonisolated struct RbMenuItem: Sendable, Equatable, Decodable {
    public var id: Int64
    /// `command`, `check`, `radio`, `separator`, `submenu`, `group`, `option`.
    public var type: String
    public var label: String
    public var enabled: Bool
    public var checked: Bool
    public var items: [RbMenuItem]
}
#endif
