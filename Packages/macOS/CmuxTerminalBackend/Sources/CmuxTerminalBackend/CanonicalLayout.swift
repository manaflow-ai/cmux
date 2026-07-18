/// A canonical binary split tree whose leaves reference screen panes.
public indirect enum CanonicalLayout: Codable, Equatable, Sendable {
    /// The deepest accepted binary split tree, counting the root as depth one.
    public static let maximumDepth = 128

    /// A leaf containing one pane's numeric and stable identifiers.
    case leaf(pane: UInt64, paneUUID: PaneID)

    /// A split whose children divide the available space by the supplied ratio.
    case split(
        direction: CanonicalSplitDirection,
        ratio: Float,
        first: CanonicalLayout,
        second: CanonicalLayout
    )

    enum CodingKeys: String, CodingKey {
        case type, pane, ratio, dir, a, b
        case paneUUID = "pane_uuid"
    }

    /// Decodes and locally validates a canonical layout node.
    ///
    /// - Parameter decoder: The decoder containing a `leaf` or `split` node.
    /// - Throws: A decoding error, ``CanonicalTopologyError/invalidSplitRatio(_:)``,
    ///   or ``BackendProtocolError/invalidTopology(_:)`` for an unknown node type.
    public init(from decoder: any Decoder) throws {
        let depth = 1 + decoder.codingPath.lazy.filter {
            $0.stringValue == CodingKeys.a.stringValue
                || $0.stringValue == CodingKeys.b.stringValue
        }.count
        guard depth <= Self.maximumDepth else {
            throw CanonicalTopologyError.budgetExceeded(
                "layout depth exceeds \(Self.maximumDepth)"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "leaf":
            self = .leaf(
                pane: try container.decode(UInt64.self, forKey: .pane),
                paneUUID: try container.decode(PaneID.self, forKey: .paneUUID)
            )
        case "split":
            let ratio = try container.decode(Float.self, forKey: .ratio)
            guard ratio.isFinite, ratio > 0, ratio < 1 else {
                throw CanonicalTopologyError.invalidSplitRatio(ratio)
            }
            self = .split(
                direction: try container.decode(CanonicalSplitDirection.self, forKey: .dir),
                ratio: ratio,
                first: try container.decode(CanonicalLayout.self, forKey: .a),
                second: try container.decode(CanonicalLayout.self, forKey: .b)
            )
        default:
            throw BackendProtocolError.invalidTopology("unknown layout node")
        }
    }

    /// Encodes a canonical layout node using the backend wire schema.
    ///
    /// - Parameter encoder: The encoder that receives the layout node.
    /// - Throws: Any error raised while encoding the node and its children.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane, let paneUUID):
            try container.encode("leaf", forKey: .type)
            try container.encode(pane, forKey: .pane)
            try container.encode(paneUUID, forKey: .paneUUID)
        case .split(let direction, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(direction, forKey: .dir)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .a)
            try container.encode(second, forKey: .b)
        }
    }

    func collectPaneIDs(
        into paneIDs: inout Set<PaneID>,
        panesByNumber: [UInt64: CanonicalPane],
        depth: Int = 1
    ) throws {
        guard depth <= Self.maximumDepth else {
            throw CanonicalTopologyError.budgetExceeded(
                "layout depth exceeds \(Self.maximumDepth)"
            )
        }
        switch self {
        case .leaf(let number, let uuid):
            guard let pane = panesByNumber[number], uuid == pane.uuid,
                  paneIDs.insert(pane.uuid).inserted else {
                throw CanonicalTopologyError.invalidReference("layout leaf")
            }
        case .split(_, let ratio, let first, let second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else {
                throw CanonicalTopologyError.invalidSplitRatio(ratio)
            }
            try first.collectPaneIDs(
                into: &paneIDs,
                panesByNumber: panesByNumber,
                depth: depth + 1
            )
            try second.collectPaneIDs(
                into: &paneIDs,
                panesByNumber: panesByNumber,
                depth: depth + 1
            )
        }
    }
}
