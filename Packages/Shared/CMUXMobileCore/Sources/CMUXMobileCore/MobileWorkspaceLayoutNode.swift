/// A recursive node in a mirrored Mac workspace pane tree.
public indirect enum MobileWorkspaceLayoutNode: Codable, Equatable, Sendable {
    /// A leaf pane containing ordered tabs.
    case pane(MobileWorkspacePane)
    /// A split containing two child nodes.
    case split(MobileWorkspaceSplit)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    private enum NodeType: String, Codable {
        case pane
        case split
    }

    /// Decodes the stable tagged-node wire representation.
    /// - Parameter decoder: The decoder providing the node payload.
    /// - Throws: A decoding error when the node tag or associated payload is invalid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .pane:
            self = .pane(try container.decode(MobileWorkspacePane.self, forKey: .pane))
        case .split:
            self = .split(try container.decode(MobileWorkspaceSplit.self, forKey: .split))
        }
    }

    /// Encodes the node using a stable type tag and associated payload.
    /// - Parameter encoder: The encoder receiving the node payload.
    /// - Throws: An encoding error from the destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(pane):
            try container.encode(NodeType.pane, forKey: .type)
            try container.encode(pane, forKey: .pane)
        case let .split(split):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}
