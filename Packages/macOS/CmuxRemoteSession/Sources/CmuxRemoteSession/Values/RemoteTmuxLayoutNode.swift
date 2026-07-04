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
    /// The node payload: one tmux pane or a split subtree.
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

    /// Creates a parsed tmux layout node.
    ///
    /// - Parameter width: Width of the node in terminal cells.
    /// - Parameter height: Height of the node in terminal cells.
    /// - Parameter x: X offset from the window's top-left, in cells.
    /// - Parameter y: Y offset from the window's top-left, in cells.
    /// - Parameter content: The node's pane or split content.
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

    /// Decodes a tmux layout node from its JSON representation.
    ///
    /// - Parameter decoder: The decoder containing width, height, origin, and
    ///   exactly one of `pane`, `horizontal`, or `vertical`.
    public init(from decoder: any Decoder) throws {
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

    /// Encodes a tmux layout node to its JSON representation.
    ///
    /// - Parameter encoder: The encoder that receives width, height, origin, and
    ///   the node content key.
    public func encode(to encoder: any Encoder) throws {
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

    /// Composes a tmux client grid for this subtree from each leaf pane's grid,
    /// matching tmux's own window geometry.
    ///
    /// A horizontal (side-by-side) split's width is the sum of its children's
    /// widths plus one divider column between each adjacent pair; a vertical
    /// (stacked) split's height is the sum of its children's heights plus one
    /// divider row between each adjacent pair. The perpendicular axis takes the
    /// smallest child capacity: valid tmux claimed geometry has equal capacity
    /// across siblings, while rendered cmux grids can differ when sibling
    /// subtrees contain different numbers of pane headers. Choosing the smaller
    /// visible capacity avoids telling tmux a nested branch can display more rows
    /// or columns than its panes actually have.
    ///
    /// Feeding each leaf its ON-SCREEN rendered grid (which already excludes
    /// cmux's per-pane header) yields the client size that matches what is
    /// actually visible, so tmux is never told the panes are taller than the
    /// terminal area — the over-count that clipped alt-screen TUIs at the top
    /// after an in-tab split (https://github.com/manaflow-ai/cmux/issues/7053).
    ///
    /// - Parameter paneGrid: the `(columns, rows)` for a leaf pane id, or `nil`
    ///   when that pane has no grid yet.
    /// - Returns: the composed grid, or `nil` as soon as any leaf's `paneGrid` is
    ///   `nil` — so a partially-rendered layout never reports a short client size.
    public func composedClientGrid(
        paneGrid: (_ paneId: Int) -> (columns: Int, rows: Int)?
    ) -> (columns: Int, rows: Int)? {
        switch content {
        case let .pane(paneId):
            // Source the pane's ON-SCREEN rendered grid (excludes the per-pane
            // header), so the composed client size matches what is actually visible
            // rather than tmux's claimed geometry. `nil` (pane not live yet)
            // propagates up so the caller can wait for the surface readiness signal.
            return paneGrid(paneId)
        case let .horizontal(children):
            var columns = 0
            var rows: Int?
            for child in children {
                guard let grid = child.composedClientGrid(paneGrid: paneGrid) else { return nil }
                columns += grid.columns
                rows = rows.map { min($0, grid.rows) } ?? grid.rows
            }
            return (columns: columns + max(0, children.count - 1), rows: rows ?? 0)
        case let .vertical(children):
            var columns: Int?
            var rows = 0
            for child in children {
                guard let grid = child.composedClientGrid(paneGrid: paneGrid) else { return nil }
                columns = columns.map { min($0, grid.columns) } ?? grid.columns
                rows += grid.rows
            }
            return (columns: columns ?? 0, rows: rows + max(0, children.count - 1))
        }
    }
}
