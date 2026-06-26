import Foundation

/// A node in a tmux window's pane-layout tree, parsed from a tmux
/// `#{window_layout}` / `%layout-change` string by ``RemoteTmuxRawLayoutParser``.
///
/// Each node carries its geometry (`width`/`height`/`x`/`y`, in terminal cells)
/// and is either a leaf pane or a split containing child nodes, mirroring tmux's
/// layout semantics: `horizontal` children are arranged left→right, `vertical`
/// children top→bottom.
///
/// The JSON shape (one of `pane`/`horizontal`/`vertical` is present):
/// ```json
/// { "width": 80, "height": 24, "x": 0, "y": 0,
///   "horizontal": [ { …, "pane": 1 }, { …, "pane": 2 } ] }
/// ```
public struct RemoteTmuxLayoutNode: Sendable, Equatable, Codable {
    public typealias Content = RemoteTmuxLayoutContent

    /// Width of the node in terminal cells.
    public let width: Int
    /// Height of the node in terminal cells.
    public let height: Int
    /// X offset from the window's top-left, in cells.
    public let x: Int
    /// Y offset from the window's top-left, in cells.
    public let y: Int
    /// The node's content: a leaf pane or a split.
    public let content: Content

    public init(width: Int, height: Int, x: Int, y: Int, content: Content) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, x, y, pane, horizontal, vertical
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        x = try container.decode(Int.self, forKey: .x)
        y = try container.decode(Int.self, forKey: .y)
        if let paneId = try container.decodeIfPresent(Int.self, forKey: .pane) {
            content = .pane(paneId)
        } else if let children = try container.decodeIfPresent([RemoteTmuxLayoutNode].self, forKey: .horizontal) {
            content = .horizontal(children)
        } else if let children = try container.decodeIfPresent([RemoteTmuxLayoutNode].self, forKey: .vertical) {
            content = .vertical(children)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "layout node missing pane/horizontal/vertical"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        switch content {
        case let .pane(id): try container.encode(id, forKey: .pane)
        case let .horizontal(children): try container.encode(children, forKey: .horizontal)
        case let .vertical(children): try container.encode(children, forKey: .vertical)
        }
    }

    /// All pane ids in this subtree, in depth-first left-to-right order — the
    /// natural order to create matching cmux splits.
    public var paneIDsInOrder: [Int] {
        switch content {
        case let .pane(id):
            return [id]
        case let .horizontal(children), let .vertical(children):
            return children.flatMap { $0.paneIDsInOrder }
        }
    }
}
