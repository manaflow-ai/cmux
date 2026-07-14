/// Classifies one changed file while preserving statuses introduced by newer Macs.
public enum MobileChangesFileStatus: Codable, Sendable, Equatable {
    /// A tracked file was added.
    case added
    /// A tracked file was modified.
    case modified
    /// A tracked file was deleted.
    case deleted
    /// A tracked file was renamed.
    case renamed
    /// A tracked file was copied.
    case copied
    /// An untracked working-tree file was added.
    case untracked
    /// A status introduced by a newer host that this client does not yet interpret.
    case unknown(String)

    /// The exact string carried on the wire.
    public var wireValue: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .untracked: "untracked"
        case let .unknown(value): value
        }
    }

    /// Decodes a known status or preserves an unknown wire value.
    /// - Parameter decoder: The decoder containing one status string.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "added": .added
        case "modified": .modified
        case "deleted": .deleted
        case "renamed": .renamed
        case "copied": .copied
        case "untracked": .untracked
        default: .unknown(value)
        }
    }

    /// Encodes the exact known or forward-compatible status string.
    /// - Parameter encoder: The encoder receiving one status string.
    /// - Throws: An encoding error from the destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
