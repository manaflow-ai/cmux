import Foundation

// MARK: Wire shapes (cmux-layout-reducer `optimistic`: facts and spots in, a patch out)
extension OptimisticRules {
    struct FinalIndex: Decodable { let final: Int }

    /// What a spot's walk looks for.
    enum Match {
        /// A leaf showing the pane.
        case leaf(PaneID)
        /// A split under that daemon handle.
        case split(SplitID)
        /// A leaf showing the pane, or a stack holding it.
        case holding(PaneID)

        func matches(_ node: LayoutNode) -> Bool {
            switch (self, node) {
            case (.leaf(let pane), .leaf(let leaf)), (.holding(let pane), .leaf(let leaf)): leaf == pane
            case (.split(let handle), .split(let id, _, _, _, _, _)): id == handle
            case (.holding(let pane), .stack(let panes, _)): panes.contains(pane)
            default: false
            }
        }
    }

    /// One tree's found node: the screen's (no `column`), a column's, or a column's row's.
    struct Spot: Encodable {
        let column: Int?
        let row: Int?
        /// Steps from the tree's root to `node` (`true` for `b`).
        let path: [Bool]
        let node: LayoutNode?

        enum CodingKeys: String, CodingKey {
            case column, row, root, node, type, pane, split, panes, expanded
            case lastPane = "last_pane"
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(column, forKey: .column)
            try c.encodeIfPresent(row, forKey: .row)
            guard let node else { return try c.encodeNil(forKey: .node) }
            if path.isEmpty { try c.encode(true, forKey: .root) }
            var n = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .node)
            switch node {
            case .leaf(let pane):
                try n.encode("leaf", forKey: .type)
                try n.encode(pane, forKey: .pane)
            case .split(let id, _, _, _, _, _):
                try n.encode("split", forKey: .type)
                try n.encodeIfPresent(id, forKey: .split)
                try n.encodeIfPresent(node.lastPane, forKey: .lastPane)
            case .stack(let panes, let expanded):
                try n.encode("stack", forKey: .type)
                try n.encode(panes, forKey: .panes)
                try n.encode(expanded, forKey: .expanded)
            case .unknown:
                try n.encode("unknown", forKey: .type)
            }
        }
    }

    /// What a rule reads of the screen; a field left nil is not sent (the rule's default).
    struct Facts: Encodable {
        var leafPlaced: Bool?
        var zoomed: Bool?
        var columns: Int?
        var panes: Int?
        var targetIndex: Int?
        var inScreen: Bool?
        var column: Int?
        var span: [Int]?
        var rows: Int?
        var row: Int?
        var dockEdges: [String]?

        enum CodingKeys: String, CodingKey {
            case zoomed, columns, panes, column, span, rows, row
            case leafPlaced = "leaf_placed"
            case targetIndex = "target_index"
            case inScreen = "in_screen"
            case dockEdges = "dock_edges"
        }
    }

    /// A rule's answer: edits to the request's spots, the screen's new tree, and column edits.
    struct Patch: Decodable {
        let spots: [SpotEdit]
        let layout: Part?
        let columns: [ColumnEdit]
        let paneAt: Int?

        enum CodingKeys: String, CodingKey {
            case spots, layout, columns
            case paneAt = "pane_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spots = try c.decodeIfPresent([SpotEdit].self, forKey: .spots) ?? []
            layout = try c.decodeIfPresent(Part.self, forKey: .layout)
            columns = try c.decodeIfPresent([ColumnEdit].self, forKey: .columns) ?? []
            paneAt = try c.decodeIfPresent(Int.self, forKey: .paneAt)
        }
    }

    /// Spot `spot`'s node replaced by `node`; nil `node` takes it out (its parent split collapses).
    struct SpotEdit: Decodable {
        let spot: Int
        let node: Part?
    }

    /// A node of a patch: a new one, or a reference to a tree as it was.
    indirect enum Part: Decodable {
        case leaf(PaneID)
        /// A new split (no daemon handle), under public id `splitID`.
        case split(splitID: String?, direction: SplitDirection, ratio: Double, a: Part, b: Part)
        case stack(panes: [PaneID], expanded: PaneID)
        /// The spot's node as it was.
        case held
        /// The screen's tree before the patch.
        case screen
        /// The edited column's tree before this edit.
        case column
        /// The edited column's row's tree before this edit.
        case row(Int)

        enum CodingKeys: String, CodingKey {
            case type, pane, dir, ratio, a, b, panes, expanded, row
            case splitID = "split_id"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "leaf": self = .leaf(try c.decode(PaneID.self, forKey: .pane))
            case "split":
                self = .split(splitID: try c.decodeIfPresent(String.self, forKey: .splitID),
                              direction: try c.decode(SplitDirection.self, forKey: .dir), ratio: try c.decode(Double.self, forKey: .ratio),
                              a: try c.decode(Part.self, forKey: .a), b: try c.decode(Part.self, forKey: .b))
            case "stack":
                self = .stack(panes: try c.decode([PaneID].self, forKey: .panes), expanded: try c.decode(PaneID.self, forKey: .expanded))
            case "held": self = .held
            case "screen": self = .screen
            case "column": self = .column
            case "row": self = .row(try c.decode(Int.self, forKey: .row))
            default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown patch part")
            }
        }

        /// The tree this part names; nil when it names one that is not there (`held` outside a spot edit,
        /// `column` or `row` outside a column change).
        func node(held: LayoutNode?, screen: LayoutNode, column: ColumnSnapshot?) -> LayoutNode? {
            switch self {
            case .leaf(let pane): return .leaf(pane)
            case .split(let splitID, let direction, let ratio, let a, let b):
                guard let a = a.node(held: held, screen: screen, column: column),
                      let b = b.node(held: held, screen: screen, column: column) else { return nil }
                return .split(id: nil, resourceID: splitID.map(ResourceID.init(rawValue:)), direction: direction, ratio: ratio, a: a, b: b)
            case .stack(let panes, let expanded): return .stack(panes: panes, expanded: expanded)
            case .held: return held
            case .screen: return screen
            case .column: return column?.layout
            case .row(let k):
                return column?.rows[checked: k]?.layout
            }
        }
    }

    struct NewRow: Decodable {
        let id: RowID
        let height: Int
        let layout: Part
    }

    struct NewColumn: Decodable {
        let id: ColumnID
        let width: Double
        let layout: Part
        let dock: DockSnapshot?
        let rows: [NewRow]

        enum CodingKeys: String, CodingKey { case id, width, layout, dock, rows }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(ColumnID.self, forKey: .id)
            width = try c.decode(Double.self, forKey: .width)
            layout = try c.decode(Part.self, forKey: .layout)
            dock = try c.decodeIfPresent(DockSnapshot.self, forKey: .dock)
            rows = try c.decodeIfPresent([NewRow].self, forKey: .rows) ?? []
        }

        func column(screen: LayoutNode) -> ColumnSnapshot? {
            guard let tree = layout.node(held: nil, screen: screen, column: nil) else { return nil }
            var rows: [RowSnapshot] = []
            for row in self.rows {
                guard let layout = row.layout.node(held: nil, screen: screen, column: nil) else { return nil }
                rows.append(RowSnapshot(id: row.id, height: row.height, layout: layout))
            }
            return ColumnSnapshot(id: id, width: width, layout: tree, dock: dock, rows: rows)
        }
    }

    enum ColumnEdit: Decodable {
        case insert(at: Int, NewColumn)
        case remove(at: Int)
        /// `layout` replaces the column's tree; `rows` edits apply in order.
        case change(at: Int, layout: Part?, rows: [RowEdit])

        enum CodingKeys: String, CodingKey { case edit, at, layout, rows }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let at = try c.decode(Int.self, forKey: .at)
            switch try c.decode(String.self, forKey: .edit) {
            case "insert": self = .insert(at: at, try NewColumn(from: decoder))
            case "remove": self = .remove(at: at)
            case "change":
                self = .change(at: at, layout: try c.decodeIfPresent(Part.self, forKey: .layout),
                               rows: try c.decodeIfPresent([RowEdit].self, forKey: .rows) ?? [])
            default: throw DecodingError.dataCorruptedError(forKey: .edit, in: c, debugDescription: "unknown column edit")
            }
        }
    }

    enum RowEdit: Decodable {
        case insert(at: Int, NewRow)
        case remove(at: Int)

        enum CodingKeys: String, CodingKey { case edit, at }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let at = try c.decode(Int.self, forKey: .at)
            switch try c.decode(String.self, forKey: .edit) {
            case "insert": self = .insert(at: at, try NewRow(from: decoder))
            case "remove": self = .remove(at: at)
            default: throw DecodingError.dataCorruptedError(forKey: .edit, in: c, debugDescription: "unknown row edit")
            }
        }
    }

    struct WireDock: Encodable {
        let edge: String
        let mode: String
        let role: String?
        let pinned: Bool
        let allowTabs: Bool

        init(_ dock: DockSnapshot) {
            edge = dock.edge.rawValue
            mode = dock.mode.rawValue
            role = dock.role?.rawValue
            pinned = dock.isPinned
            allowTabs = dock.allowsTabs
        }

        enum CodingKeys: String, CodingKey {
            case edge, mode, role, pinned
            case allowTabs = "allow_tabs"
        }
    }

    struct WireColumnSpec: Encodable {
        let handle: UInt64
        let width: Double
        let left: Bool
    }

    struct WireRowSpec: Encodable {
        let handle: UInt64
        let height: Int
    }

    struct SplitRequest: Encodable {
        let op = "split"
        let target: PaneID
        let dir: SplitDirection
        let ratio: Double
        let leaf: PaneID
        let splitID: String
        let column: WireColumnSpec?
        let row: WireRowSpec?
        let around: SplitID?
        let before: Bool?
        let facts: Facts
        let spots: [Spot]

        enum CodingKeys: String, CodingKey {
            case op, target, dir, ratio, leaf, column, row, around, before, facts, spots
            case splitID = "split_id"
        }
    }

    struct DockRequest: Encodable {
        let op = "dock"
        let leaf: PaneID
        let column: WireColumnSpec
        let dock: WireDock
        let facts: Facts
    }

    struct RemovePaneRequest: Encodable {
        let op = "remove_pane"
        let pane: PaneID
        let spots: [Spot]
    }

    struct MoveTabRequest: Encodable {
        let op = "move_tab"
        let samePane: Bool
        let from: Int
        let index: Int
        let targetCount: Int

        enum CodingKeys: String, CodingKey {
            case op, from, index
            case samePane = "same_pane"
            case targetCount = "target_count"
        }
    }

    struct PlaceWorkspaceRequest: Encodable {
        let op = "place_workspace"
        let groups: [String?]
        let from: Int
        let kind: OptimisticRules.PlaceKind
        let group: String?
        let index: Int

        func encode(to encoder: any Encoder) throws {
            enum Keys: String, CodingKey { case op, groups, from, kind, group, index }
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(op, forKey: .op)
            // Every slot is listed, an ungrouped one as null: the index is the daemon order's.
            var list = c.nestedUnkeyedContainer(forKey: .groups)
            for group in groups {
                if let group { try list.encode(group) } else { try list.encodeNil() }
            }
            try c.encode(from, forKey: .from)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(group, forKey: .group)
            try c.encode(index, forKey: .index)
        }
    }

    struct RowHeightsRequest: Encodable {
        let op = "row_heights"
        let rows: [RowHeightValue]
        let heights: [RowHeightValue]

        func encode(to encoder: any Encoder) throws {
            enum Keys: String, CodingKey { case op, rows, heights }
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(op, forKey: .op)
            try c.encode(rows.map { WireRowNow(id: $0.row, height: $0.height) }, forKey: .rows)
            try c.encode(heights, forKey: .heights)
        }
    }

    struct WireRowNow: Encodable {
        let id: RowID
        let height: Int
    }
}
