/// One recursive node in a synced workspace pane layout.
public indirect enum MobileWorkspaceLayoutNode: Codable, Equatable, Sendable {
    /// A branch dividing its rectangle between two child nodes.
    case split(MobileWorkspaceLayoutSplit)

    /// A leaf pane containing surface tabs.
    case pane(MobileWorkspaceLayoutPane)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    private enum Kind: String, Codable {
        case split
        case pane
    }

    /// Decodes a node from the `kind`-discriminated layout wire shape.
    ///
    /// - Parameter decoder: The decoder for one layout node.
    /// - Throws: A decoding error for an unknown kind or malformed node.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .split:
            self = try .split(MobileWorkspaceLayoutSplit(from: decoder))
        case .pane:
            self = try .pane(MobileWorkspaceLayoutPane(from: decoder))
        }
    }

    /// Encodes a node into the `kind`-discriminated layout wire shape.
    ///
    /// - Parameter encoder: The encoder receiving one layout node.
    /// - Throws: An encoding error from the destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .split(split):
            try container.encode(Kind.split, forKey: .kind)
            try split.encode(to: encoder)
        case let .pane(pane):
            try container.encode(Kind.pane, forKey: .kind)
            try pane.encode(to: encoder)
        }
    }

    func hashTopology(into hasher: inout Hasher) {
        switch self {
        case let .split(split):
            hasher.combine(Kind.split.rawValue)
            hasher.combine(split.id)
            hasher.combine(split.orientation)
            split.first.hashTopology(into: &hasher)
            split.second.hashTopology(into: &hasher)
        case let .pane(pane):
            hasher.combine(Kind.pane.rawValue)
            hasher.combine(pane.id)
            hasher.combine(pane.selectedSurfaceID)
            hasher.combine(pane.surfaces.map(\.id))
        }
    }
}
