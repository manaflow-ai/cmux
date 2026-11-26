import CCmuxLayoutReducerFFI
import Foundation

/// The pane close rules, asked of the layout reducer (cmux-layout-reducer `pane_close.rs` behind the
/// `pane_close_*` ops of `cmux_layout_reducer_json`, with its tests and `schemas/pane-close/vectors.json`):
/// what a close shows, its successor, the overlay of pending closes, the landed close sizes and the
/// sizing intents after a daemon tree. ``LayoutModel`` owns the holds and sends what the answers say;
/// nothing here decides.
nonisolated enum PaneCloseRules {
    /// `layout.splitSizing` even, `layout.newColumnWidth` fitScreen.
    struct Sizing: Encodable {
        var even: Bool
        var fits: Bool
    }

    /// Sizes of closes that landed while another close on their screen was pending.
    struct Landed: Codable {
        var ratios: [String: Double] = [:]
        var widths: [String: Double] = [:]

        init(ratios: [SplitID: Double], widths: [ColumnID: Double]) {
            self.ratios = Dictionary(uniqueKeysWithValues: ratios.map { ($0.key.rawValue, $0.value) })
            self.widths = Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value) })
        }

        var splitRatios: [SplitID: Double] { Dictionary(uniqueKeysWithValues: ratios.map { (SplitID($0.key), $0.value) }) }
        var columnWidths: [ColumnID: Double] { Dictionary(uniqueKeysWithValues: widths.map { (ColumnID($0.key), $0.value) }) }
    }

    struct Screen: Encodable {
        var id: String
        var zoomed: Bool
        var layout: Wire

        init(_ screen: LayoutScreen) {
            id = screen.id.rawValue
            zoomed = screen.zoomed
            layout = Wire(screen.layout)
        }
    }

    struct Change: Decodable {
        var split: String
        var ratio: Double
    }

    struct Resize: Decodable {
        var column: String
        var width: Double
    }

    struct Shown: Decodable {
        var after: Wire
        var successor: String?
        var splits: [String]
        var columns: [String]
    }

    struct Intents: Decodable {
        var ratios: [Change]
        var widths: [Resize]
    }

    struct Flush: Decodable {
        var ratios: [Change]
        var widths: [Resize]
        var landed: Landed
    }

    /// Asks `operation` with `request`; nil when the reducer does not answer.
    static func ask<Reply: Decodable>(_ operation: String, _ request: some Encodable) -> Reply? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var output = [UInt8](repeating: 0, count: max(4096, data.count * 2)), length = 0
        for _ in 0..<2 {
            let code: Int32 = data.withUnsafeBytes { request in
                operation.withCString { operation in
                    output.withUnsafeMutableBytes { buffer in
                        cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                                 buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > output.count {
                output = [UInt8](repeating: 0, count: length)
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= output.count else { return nil }
            return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(length)))
        }
        return nil
    }

    /// A ``ScreenLayout`` in the reducer's JSON (`screen_layout.rs`): `{"splits": node}` or
    /// `{"columns": [...]}`; a node is `{"pane"}` or `{"split", "axis", "ratio", "a", "b"}`.
    struct Wire: Codable {
        var layout: ScreenLayout

        init(_ layout: ScreenLayout) { self.layout = layout }

        private enum Key: String, CodingKey {
            case splits, columns, pane, split, axis, ratio, a, b, id, width, root, dock, rows, height
            case edge, mode, role, isPinned, allowsTabs
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch layout {
            case let .splits(root): try container.encode(Node(root), forKey: .splits)
            case let .columns(columns): try container.encode(columns.map(Column.init), forKey: .columns)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if let root = try container.decodeIfPresent(Node.self, forKey: .splits) {
                layout = .splits(root.node)
            } else {
                layout = .columns(try container.decode([Column].self, forKey: .columns).map(\.column))
            }
        }

        struct Node: Codable {
            var node: SplitNode

            init(_ node: SplitNode) { self.node = node }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                switch node {
                case let .leaf(pane): try container.encode(pane.rawValue, forKey: .pane)
                case let .split(id, axis, ratio, a, b):
                    try container.encode(id.rawValue, forKey: .split)
                    try container.encode(axis.rawValue, forKey: .axis)
                    try container.encode(ratio, forKey: .ratio)
                    try container.encode(Node(a), forKey: .a)
                    try container.encode(Node(b), forKey: .b)
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                if let pane = try container.decodeIfPresent(String.self, forKey: .pane) {
                    node = .leaf(PaneID(pane))
                    return
                }
                guard let axis = SplitAxis(rawValue: try container.decode(String.self, forKey: .axis)) else {
                    throw DecodingError.dataCorruptedError(forKey: .axis, in: container, debugDescription: "axis")
                }
                node = .split(SplitID(try container.decode(String.self, forKey: .split)), axis: axis,
                              ratio: try container.decode(Double.self, forKey: .ratio),
                              a: try container.decode(Node.self, forKey: .a).node,
                              b: try container.decode(Node.self, forKey: .b).node)
            }
        }

        struct Column: Codable {
            var column: LayoutColumn

            init(_ column: LayoutColumn) { self.column = column }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(column.id.rawValue, forKey: .id)
                try container.encode(column.width, forKey: .width)
                try container.encode(Node(column.root), forKey: .root)
                if let dock = column.dock { try container.encode(Dock(dock), forKey: .dock) }
                if !column.rows.isEmpty { try container.encode(column.rows.map(Row.init), forKey: .rows) }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                column = LayoutColumn(id: ColumnID(try container.decode(String.self, forKey: .id)),
                                      width: try container.decode(Double.self, forKey: .width),
                                      root: try container.decode(Node.self, forKey: .root).node,
                                      dock: try container.decodeIfPresent(Dock.self, forKey: .dock)?.dock,
                                      rows: try container.decodeIfPresent([Row].self, forKey: .rows)?.map(\.row) ?? [])
            }
        }

        struct Row: Codable {
            var row: LayoutRow

            init(_ row: LayoutRow) { self.row = row }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(row.id.rawValue, forKey: .id)
                try container.encode(row.height, forKey: .height)
                try container.encode(Node(row.root), forKey: .root)
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                row = LayoutRow(id: RowID(try container.decode(String.self, forKey: .id)),
                                height: try container.decode(Int.self, forKey: .height),
                                root: try container.decode(Node.self, forKey: .root).node)
            }
        }

        struct Dock: Codable {
            var dock: DockColumn

            init(_ dock: DockColumn) { self.dock = dock }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(dock.edge.rawValue, forKey: .edge)
                try container.encode(dock.mode.rawValue, forKey: .mode)
                if let role = dock.role { try container.encode(role.rawValue, forKey: .role) }
                try container.encode(dock.isPinned, forKey: .isPinned)
                try container.encode(dock.allowsTabs, forKey: .allowsTabs)
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                guard let edge = DockEdge(rawValue: try container.decode(String.self, forKey: .edge)),
                      let mode = DockMode(rawValue: try container.decode(String.self, forKey: .mode)) else {
                    throw DecodingError.dataCorruptedError(forKey: .edge, in: container, debugDescription: "dock")
                }
                dock = DockColumn(edge: edge, mode: mode,
                                  role: try container.decodeIfPresent(String.self, forKey: .role).flatMap(DockRole.init(rawValue:)),
                                  isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
                                  allowsTabs: try container.decodeIfPresent(Bool.self, forKey: .allowsTabs) ?? false)
            }
        }
    }
}
