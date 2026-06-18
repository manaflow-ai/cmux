import Foundation

/// Pure builder for the `cmux cluster-ssh` / `cssh` grid layout.
///
/// Produces a `CmuxLayoutNode` JSON object — the same shape
/// `cmux workspace create --layout <json>` accepts:
///   - split node: `{"direction":"horizontal|vertical","split":<0..1>,"children":[a,b]}`
///   - leaf pane:  `{"pane":{"surfaces":[{"type":"terminal","command":..,"name":..}]}}`
/// where `horizontal` = side-by-side (columns) and `vertical` = stacked (rows).
///
/// Kept dependency-free (Foundation only) so this one file can be compiled into
/// both the `cmux-cli` executable and the `cmuxTests` bundle, letting the grid
/// math be unit-tested directly (mirrors `CLI/FeedEventClassifier.swift`).
enum ClusterSSHLayoutBuilder {
    /// One terminal pane: the shell command to run and the label shown on its tab.
    struct Pane: Equatable {
        let command: String
        let name: String
    }

    /// Resolves `(columns, rows)` for `count` panes.
    ///
    /// `columns` wins over `rows` when both are given. With neither, a near-square
    /// grid is chosen (columns = ceil(sqrt(count)), matching csshX-style layouts).
    static func gridDimensions(count: Int, columns: Int?, rows: Int?) -> (columns: Int, rows: Int) {
        let n = max(1, count)
        func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / max(1, b) }
        if let columns, columns > 0 {
            let c = min(columns, n)
            return (c, ceilDiv(n, c))
        }
        if let rows, rows > 0 {
            let r = min(rows, n)
            let c = ceilDiv(n, r)
            return (c, ceilDiv(n, c))
        }
        let c = max(1, Int(Double(n).squareRoot().rounded(.up)))
        return (c, ceilDiv(n, c))
    }

    /// Builds the grid layout node for `panes`. Returns a single leaf when there
    /// is only one pane (no split). `panes` must be non-empty.
    static func layout(panes: [Pane], columns: Int? = nil, rows: Int? = nil) -> [String: Any] {
        let leaves = panes.map(leafNode)
        guard leaves.count > 1 else {
            return leaves.first ?? leafNode(Pane(command: "", name: ""))
        }

        let (cols, _) = gridDimensions(count: leaves.count, columns: columns, rows: rows)

        // Chunk leaves into rows of up to `cols` columns, top to bottom.
        var rowChunks: [[[String: Any]]] = []
        var index = 0
        while index < leaves.count {
            let end = min(index + cols, leaves.count)
            rowChunks.append(Array(leaves[index..<end]))
            index = end
        }

        // Each row is a horizontal (side-by-side) tree; rows stack vertically.
        let rowNodes = rowChunks.map { balancedSplit($0, direction: "horizontal") }
        return balancedSplit(rowNodes, direction: "vertical")
    }

    private static func leafNode(_ pane: Pane) -> [String: Any] {
        var surface: [String: Any] = ["type": "terminal", "command": pane.command]
        if !pane.name.isEmpty {
            surface["name"] = pane.name
        }
        return ["pane": ["surfaces": [surface]]]
    }

    /// Balanced binary split tree over `nodes`. The `split` ratio (first child's
    /// fraction = leftCount/totalCount) keeps every leaf roughly equal in size.
    private static func balancedSplit(_ nodes: [[String: Any]], direction: String) -> [String: Any] {
        guard nodes.count > 1 else {
            return nodes.first ?? [:]
        }
        let mid = nodes.count / 2
        let left = balancedSplit(Array(nodes[0..<mid]), direction: direction)
        let right = balancedSplit(Array(nodes[mid...]), direction: direction)
        return [
            "direction": direction,
            "split": Double(mid) / Double(nodes.count),
            "children": [left, right],
        ]
    }
}
