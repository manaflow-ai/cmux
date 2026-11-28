import CCmuxLayoutReducerFFI
import Foundation

/// The sizes of closes that landed while others were pending (`LayoutModel.landedCloseSizes`), until the daemon
/// has them: ratios by split, widths by column.
nonisolated struct LandedCloseSizes: Codable, Equatable {
    var ratios: [String: Double] = [:]
    var widths: [String: Double] = [:]
    var isEmpty: Bool { ratios.isEmpty && widths.isEmpty }
}

/// A reply of the pane close rules, run by cmux-layout-reducer (`pane_close`, ops `pane_close_*` of
/// `cmux_layout_reducer_json`; its tests and `schemas/pane-close/vectors.json`, the answers these rules gave in
/// Swift). One call per close shown, per snapshot that drops a pane or lands a close, and per screen layout while
/// a close is pending; none while no close is pending or landed.
nonisolated struct PaneCloseReply: Decodable {
    /// `layout.splitSizing` even, `layout.newColumnWidth` fitScreen.
    struct Sizing: Encodable {
        var even: Bool
        var fits: Bool
    }

    struct Screen: Encodable {
        var id: ScreenID
        var zoomed: Bool
        var layout: ScreenLayout
        init(_ screen: LayoutScreen) { (id, zoomed, layout) = (screen.id, screen.zoomed, screen.layout) }
    }

    struct Shown: Decodable {
        var successor: PaneID?
        var splits: [SplitID]
        var columns: [ColumnID]
    }

    var layout: ScreenLayout?
    var shown: Shown?
    var landed: LandedCloseSizes?
    var ratios: [SplitRatioChange]?
    var widths: [ColumnResize]?
    var changes: [SplitRatioChange]?

    /// Rust's answer to `operation` (nil when it does not answer).
    static func call(_ operation: String, _ request: some Encodable) -> PaneCloseReply? {
        guard let request = try? JSONEncoder().encode(request) else { return nil }
        var capacity = 2 * request.count + 1024
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { bytes in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return try? JSONDecoder().decode(Self.self, from: Data(output.prefix(length)))
        }
        return nil
    }

    /// The even ratios `pane`'s close leaves its same-axis chain between `old` and `new`.
    static func splitChanges(old: ScreenLayout, new: ScreenLayout, closing pane: PaneID) -> [SplitRatioChange] {
        struct Request: Encodable { var old, new: ScreenLayout, pane: PaneID }
        return call("pane_close_split_changes", Request(old: old, new: new, pane: pane))?.changes ?? []
    }
}

/// `screen_layout`'s JSON: a leaf `{"pane"}`, a split `{"split", "axis", "ratio", "a", "b"}`.
nonisolated extension SplitNode: Codable {
    private enum Keys: String, CodingKey { case pane, split, axis, ratio, a, b }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let pane = try c.decodeIfPresent(PaneID.self, forKey: .pane) {
            self = .leaf(pane)
        } else {
            self = .split(try c.decode(SplitID.self, forKey: .split), axis: try c.decode(SplitAxis.self, forKey: .axis),
                          ratio: try c.decode(Double.self, forKey: .ratio), a: try c.decode(SplitNode.self, forKey: .a),
                          b: try c.decode(SplitNode.self, forKey: .b))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .leaf(pane): try c.encode(pane, forKey: .pane)
        case let .split(id, axis, ratio, a, b):
            try c.encode(id, forKey: .split)
            try c.encode(axis, forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }
}

/// `screen_layout`'s JSON: `{"splits": node}` or `{"columns": [column]}`.
nonisolated extension ScreenLayout: Codable {
    private enum Keys: String, CodingKey { case splits, columns }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let root = try c.decodeIfPresent(SplitNode.self, forKey: .splits) {
            self = .splits(root)
        } else {
            self = .columns(try c.decode([LayoutColumn].self, forKey: .columns))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .splits(root): try c.encode(root, forKey: .splits)
        case let .columns(columns): try c.encode(columns, forKey: .columns)
        }
    }
}
