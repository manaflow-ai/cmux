import Foundation

struct LayoutDocument: Decodable, Sendable {
    let version: UInt32
    let screenID: String
    let activePaneID: String
    let zoomedPaneID: String?
    let root: LayoutNode

    enum CodingKeys: String, CodingKey {
        case version, root
        case screenID = "screen_id"
        case activePaneID = "active_pane_id"
        case zoomedPaneID = "zoomed_pane_id"
    }

    var visiblePaneIDs: [String] {
        if let zoomedPaneID { return [zoomedPaneID] }
        return root.visiblePaneIDs
    }
}

struct ViewportColumn: Decodable, Identifiable, Sendable {
    let columnID: String
    let width: Double
    let root: LayoutNode

    var id: String { columnID }

    enum CodingKeys: String, CodingKey {
        case width, root
        case columnID = "column_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columnID = try container.decode(String.self, forKey: .columnID)
        let decodedWidth = try container.decode(Double.self, forKey: .width)
        guard decodedWidth.isFinite, (0.1...1.0).contains(decodedWidth) else {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Viewport column width must be finite from 0.1 through 1.0."
            )
        }
        width = decodedWidth
        root = try container.decode(LayoutNode.self, forKey: .root)
    }

    func widthLabel(localization: Localization) -> String {
        localization.format("column.percent", "%d%%", Int(width * 100))
    }
}

indirect enum LayoutNode: Decodable, Sendable {
    case leaf(paneID: String, tabIDs: [String], activeTabID: String?)
    case split(
        splitID: String,
        direction: SplitDirection,
        ratio: Double,
        first: LayoutNode,
        second: LayoutNode
    )
    case stack(paneIDs: [String], expandedPaneID: String)
    case viewport(baseWidth: Double, columns: [ViewportColumn])

    enum SplitDirection: String, Decodable, Sendable {
        case horizontal
        case vertical
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ratio, direction, first, second, columns
        case paneID = "pane_id"
        case tabIDs = "tab_ids"
        case activeTabID = "active_tab_id"
        case splitID = "split_id"
        case paneIDs = "pane_ids"
        case expandedPaneID = "expanded_pane_id"
        case baseWidth = "base_width"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "leaf":
            self = .leaf(
                paneID: try container.decode(String.self, forKey: .paneID),
                tabIDs: try container.decode([String].self, forKey: .tabIDs),
                activeTabID: try container.decodeIfPresent(String.self, forKey: .activeTabID)
            )
        case "split":
            let ratio = try container.decode(Double.self, forKey: .ratio)
            guard ratio.isFinite, ratio > 0, ratio < 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ratio,
                    in: container,
                    debugDescription: "Split ratio must be finite and between zero and one."
                )
            }
            self = .split(
                splitID: try container.decode(String.self, forKey: .splitID),
                direction: try container.decode(SplitDirection.self, forKey: .direction),
                ratio: ratio,
                first: try container.decode(LayoutNode.self, forKey: .first),
                second: try container.decode(LayoutNode.self, forKey: .second)
            )
        case "stack":
            self = .stack(
                paneIDs: try container.decode([String].self, forKey: .paneIDs),
                expandedPaneID: try container.decode(String.self, forKey: .expandedPaneID)
            )
        case "viewport":
            let baseWidth = try container.decode(Double.self, forKey: .baseWidth)
            guard baseWidth.isFinite, (0.1...1.0).contains(baseWidth) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .baseWidth,
                    in: container,
                    debugDescription: "Viewport base width must be finite from 0.1 through 1.0."
                )
            }
            self = .viewport(
                baseWidth: baseWidth,
                columns: try container.decode([ViewportColumn].self, forKey: .columns)
            )
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown layout node kind \(kind)"
            )
        }
    }

    var paneIDs: [String] {
        switch self {
        case .leaf(let paneID, _, _):
            [paneID]
        case .split(_, _, _, let first, let second):
            first.paneIDs + second.paneIDs
        case .stack(let paneIDs, _):
            paneIDs
        case .viewport(_, let columns):
            columns.flatMap { $0.root.paneIDs }
        }
    }

    var visiblePaneIDs: [String] {
        switch self {
        case .leaf(let paneID, _, _):
            [paneID]
        case .split(_, _, _, let first, let second):
            first.visiblePaneIDs + second.visiblePaneIDs
        case .stack(_, let expandedPaneID):
            [expandedPaneID]
        case .viewport(_, let columns):
            columns.flatMap { $0.root.visiblePaneIDs }
        }
    }
}
