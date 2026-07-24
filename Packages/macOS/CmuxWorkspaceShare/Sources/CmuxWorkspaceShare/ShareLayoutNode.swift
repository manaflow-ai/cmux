/// A recursive terminal layout node using the TypeScript v1 wire names.
public indirect enum ShareLayoutNode: Equatable, Sendable {
    /// A two-child split.
    case split(axis: String, ratio: Double, a: ShareLayoutNode, b: ShareLayoutNode)

    /// A pane leaf. Non-terminal leaves are metadata placeholders only.
    case pane(pane: String, content: String, cols: Int?, rows: Int?, title: String?)
}

extension ShareLayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case axis
        case ratio
        case a
        case b
        case pane
        case content
        case cols
        case rows
        case title
    }

    /// Decodes the `split` and `pane` discriminated union used by protocol v1.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "split":
            self = .split(
                axis: try container.decode(String.self, forKey: .axis),
                ratio: try container.decode(Double.self, forKey: .ratio),
                a: try container.decode(ShareLayoutNode.self, forKey: .a),
                b: try container.decode(ShareLayoutNode.self, forKey: .b)
            )
        case "pane":
            self = .pane(
                pane: try container.decode(String.self, forKey: .pane),
                content: try container.decode(String.self, forKey: .content),
                cols: try container.decodeIfPresent(Int.self, forKey: .cols),
                rows: try container.decodeIfPresent(Int.self, forKey: .rows),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown workspace-share layout node kind."
            )
        }
    }

    /// Encodes the `split` and `pane` discriminated union used by protocol v1.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let axis, let ratio, let a, let b):
            try container.encode("split", forKey: .kind)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(a, forKey: .a)
            try container.encode(b, forKey: .b)
        case .pane(let pane, let content, let cols, let rows, let title):
            try container.encode("pane", forKey: .kind)
            try container.encode(pane, forKey: .pane)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(cols, forKey: .cols)
            try container.encodeIfPresent(rows, forKey: .rows)
            try container.encodeIfPresent(title, forKey: .title)
        }
    }
}
