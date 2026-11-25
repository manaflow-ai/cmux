import CCmuxLayoutReducerFFI
public import CoreGraphics
import Foundation

/// Directional pane navigation over computed frames, with focus history
/// (plans/cmux-next/focus.md section 4a).
///
/// The rule is cmux-layout-reducer's (`pane_focus::neighbor`, op `layout_pane_neighbor` of the app FFI's JSON
/// channel), the one cmux-tui's focus keys use. This maps the frames, history and columns to its rows and its
/// answer back; `PaneFocusNeighborVectorTests` checks it against the vectors the Swift rule wrote before it moved.
public nonisolated enum FocusNavigation {
    /// The pane `direction` of `pane`.
    ///
    /// Candidates lie entirely past the source edge. The adjacent ones are
    /// those that overlap the source on the perpendicular axis at the
    /// smallest distance. Among them the most recently focused
    /// wins (`recency`, newest first); without history the largest overlap, then
    /// the nearest center, then the top-left one. When no candidate overlaps,
    /// the nearest edge, then the nearest center.
    ///
    /// `columns` (column strip mode, panes per column) makes a move into
    /// another column land on that column's most recently focused pane,
    /// wherever it sits in the column (each column keeps an active tile).
    public static func neighbor(
        of pane: PaneID,
        direction: LayoutDirection,
        frames: [PaneID: CGRect],
        recency: [PaneID] = [],
        columns: [[PaneID]] = []
    ) -> PaneID? {
        guard frames[pane] != nil else { return nil }
        // One row per pane with a frame or a column; `order` breaks the last tie by the ids' text order.
        let ids = Set(frames.keys).union(columns.joined()).sorted { $0.rawValue < $1.rawValue }
        guard let source = ids.firstIndex(of: pane) else { return nil }
        let rows = ids.enumerated().map { order, id in
            Row(frame: frames[id].map(Frame.init), column: columns.firstIndex { $0.contains(id) },
                recency: recency.firstIndex(of: id), order: order)
        }
        let request = Request(panes: rows, source: source, direction: direction.wireName)
        guard let index = call(request)?.index else { return nil }
        return ids.indices.contains(index) ? ids[index] : nil
    }

    /// The member of `panes` that comes first in `recency` (newest first).
    public static func mostRecent(_ panes: [PaneID], recency: [PaneID]) -> PaneID? {
        let members = Set(panes)
        return recency.first { members.contains($0) }
    }

    private struct Frame: Encodable {
        var x, y, w, h: CGFloat

        /// The rect as its edges read it (`minX`, `maxX` of a rect with a negative size).
        init(_ rect: CGRect) {
            let rect = rect.standardized
            (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        }
    }

    private struct Row: Encodable {
        var frame: Frame?
        var column: Int?
        var recency: Int?
        var order: Int
    }

    private struct Request: Encodable {
        var panes: [Row]
        var source: Int
        var direction: String
    }

    private struct Reply: Decodable {
        var index: Int?
    }

    /// One call of the app FFI's JSON channel; nil when it refuses.
    private static func call(_ request: Request) -> Reply? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = 256
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, "layout_pane_neighbor",
                                             outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength)
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { break }
            return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(outputLength)))
        }
        assertionFailure("layout_pane_neighbor refused")
        return nil
    }
}

private extension LayoutDirection {
    var wireName: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        }
    }
}
