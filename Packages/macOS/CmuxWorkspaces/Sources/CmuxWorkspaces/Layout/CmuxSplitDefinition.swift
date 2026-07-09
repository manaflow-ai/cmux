public import Bonsplit

/// A binary split in the declarative `cmux.json` layout tree.
///
/// Carries the split orientation, an optional normalized divider position, and
/// exactly two child ``CmuxLayoutNode`` values. Decoding rejects any child count
/// other than two. ``clampedSplitPosition`` and ``splitOrientation`` expose the
/// already-resolved fields the layout walk reads.
public struct CmuxSplitDefinition: Codable, Sendable, Hashable {
    /// The split axis.
    public var direction: CmuxSplitDirection
    /// The normalized divider position in `0...1`, or `nil` for the 0.5 default.
    public var split: Double?
    /// The two child nodes, in declaration order.
    public var children: [CmuxLayoutNode]

    /// Creates a split definition with the given direction, optional divider
    /// position, and children.
    public init(direction: CmuxSplitDirection, split: Double? = nil, children: [CmuxLayoutNode]) {
        self.direction = direction
        self.split = split
        self.children = children
    }

    /// Decodes a split, requiring exactly two children.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(CmuxSplitDirection.self, forKey: .direction)
        split = try container.decodeIfPresent(Double.self, forKey: .split)
        children = try container.decode([CmuxLayoutNode].self, forKey: .children)
        if children.count != 2 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Split node requires exactly 2 children, got \(children.count)"
                )
            )
        }
    }

    /// The divider position clamped into the `0.1...0.9` usable range.
    public var clampedSplitPosition: Double {
        let value = split ?? 0.5
        return min(0.9, max(0.1, value))
    }

    /// The Bonsplit orientation matching this split's ``direction``.
    public var splitOrientation: SplitOrientation {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}
