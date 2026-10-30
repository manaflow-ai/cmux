import Foundation

public enum SplitDirection: String, Sendable, Hashable, Codable {
    /// Side by side: `a` left, `b` right.
    case right
    /// Stacked: `a` top, `b` bottom.
    case down
}

/// Canonical split tree of one screen.
public indirect enum LayoutNode: Sendable, Hashable, Decodable {
    case leaf(PaneID)
    /// `id` (the daemon's handle) is nil only on protocol v7 and older servers and on a split the
    /// app shows before the daemon has it. `resourceID` is the split's public id
    /// (`split-client-split-id-v1`): the client-minted id of an optimistic split, which the
    /// daemon's split keeps, so both are one split to the app.
    case split(id: SplitID?, resourceID: ResourceID?, direction: SplitDirection, ratio: Double, a: LayoutNode, b: LayoutNode)
    case stack(panes: [PaneID], expanded: PaneID)
    /// A node type this client does not know.
    case unknown

    enum CodingKeys: String, CodingKey {
        case type, pane, split, dir, ratio, a, b, panes, expanded
        case splitID = "split_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "leaf":
            self = .leaf(try c.decode(PaneID.self, forKey: .pane))
        case "split":
            self = .split(
                id: try c.decodeIfPresent(SplitID.self, forKey: .split),
                resourceID: try c.decodeIfPresent(ResourceID.self, forKey: .splitID),
                direction: try c.decode(SplitDirection.self, forKey: .dir),
                ratio: try c.decode(Double.self, forKey: .ratio),
                a: try c.decode(LayoutNode.self, forKey: .a),
                b: try c.decode(LayoutNode.self, forKey: .b)
            )
        case "stack":
            self = .stack(
                panes: try c.decode([PaneID].self, forKey: .panes),
                expanded: try c.decode(PaneID.self, forKey: .expanded)
            )
        default:
            self = .unknown
        }
    }

    /// Pane ids in depth-first order.
    public var paneIDs: [PaneID] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(_, _, _, _, let a, let b): a.paneIDs + b.paneIDs
        case .stack(let panes, _): panes
        case .unknown: []
        }
    }

}
