import Foundation

/// A Codable, Equatable, Sendable snapshot of a workspace's pane tree.
public indirect enum SessionWorkspaceLayoutSnapshot: Codable, Equatable, Sendable {
    /// One leaf pane with its ordered panels and selected tab.
    case pane(SessionPaneLayoutSnapshot)
    /// Two child nodes and their divider geometry.
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    /// Decodes the stable pane/split session wire format.
    ///
    /// - Parameter decoder: The decoder containing the saved node.
    /// - Throws: A decoding error for malformed or unknown node types.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionPaneLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported layout node type: \(type)"
            )
        }
    }

    /// Encodes this node using the existing session wire format.
    ///
    /// - Parameter encoder: The encoder receiving the node and its children.
    /// - Throws: An error from the encoder.
    public func encode(to encoder: any Encoder) throws {
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
