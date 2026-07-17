/// Classifies a unified-diff row while preserving kinds introduced by newer Macs.
public enum MobileChangesRowKind: Codable, Sendable, Equatable {
    /// An unchanged line present on both sides.
    case context
    /// A new-side addition.
    case add
    /// An old-side deletion.
    case del
    /// Git's marker that the preceding side lacks a trailing newline.
    case noNewline
    /// A row kind introduced by a newer host that this client does not yet interpret.
    case unknown(String)

    /// The exact string carried on the wire.
    public var wireValue: String {
        switch self {
        case .context: "context"
        case .add: "add"
        case .del: "del"
        case .noNewline: "noNewline"
        case let .unknown(value): value
        }
    }

    /// Decodes a known row kind or preserves an unknown wire value.
    /// - Parameter decoder: The decoder containing one row-kind string.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "context": .context
        case "add": .add
        case "del": .del
        case "noNewline": .noNewline
        default: .unknown(value)
        }
    }

    /// Encodes the exact known or forward-compatible row-kind string.
    /// - Parameter encoder: The encoder receiving one row-kind string.
    /// - Throws: An encoding error from the destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
