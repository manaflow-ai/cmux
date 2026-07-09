/// A node in a persisted workspace layout tree: either a leaf ``pane`` or a
/// ``split`` of two child subtrees. `indirect` so a split can recursively
/// carry layout nodes.
public indirect enum SessionWorkspaceLayoutSnapshot: Codable, Sendable {
    /// A leaf pane carrying its panel ids and selection.
    case pane(SessionPaneLayoutSnapshot)
    /// A split carrying its orientation, divider, and two child subtrees.
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    /// Decodes a layout node from its tagged `type` discriminator.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionPaneLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported layout node type: \(type)")
        }
    }

    /// Encodes a layout node with its `type` discriminator.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}
