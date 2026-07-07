/// A node in the declarative `cmux.json` workspace layout tree.
///
/// Decoded from a `layout` block, a node is either a leaf ``CmuxPaneDefinition``
/// (`pane`) or a binary ``CmuxSplitDefinition`` (`split`). The custom Codable
/// implementation enforces that a node carries exactly one of a `pane` key or a
/// `direction` key, mirroring the two cases. This value type owns the wire
/// format; the resolved walk image is ``WorkspaceCustomLayoutNode``.
public indirect enum CmuxLayoutNode: Codable, Sendable, Hashable {
    /// A leaf pane holding one or more surfaces.
    case pane(CmuxPaneDefinition)
    /// A binary split of exactly two child nodes.
    case split(CmuxSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    /// Decodes a node, requiring exactly one of a `pane` key or a `direction` key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasPane = container.contains(.pane)
        let hasDirection = container.contains(.direction)

        if hasPane && hasDirection {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "CmuxLayoutNode must not contain both 'pane' and 'direction' keys"
                )
            )
        }

        if hasPane {
            let pane = try container.decode(CmuxPaneDefinition.self, forKey: .pane)
            self = .pane(pane)
        } else if hasDirection {
            let splitDef = try CmuxSplitDefinition(from: decoder)
            self = .split(splitDef)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "CmuxLayoutNode must contain either a 'pane' key or a 'direction' key"
                )
            )
        }
    }

    /// Encodes a node back to its `pane`-keyed or `direction`-keyed wire form.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}
