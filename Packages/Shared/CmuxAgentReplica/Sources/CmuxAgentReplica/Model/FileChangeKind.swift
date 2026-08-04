import Foundation

/// Describes the kind of file mutation reported by a transcript entry.
public enum FileChangeKind: Codable, Hashable, Sendable {
    /// A file write.
    case write
    /// A file edit.
    case edit
    /// A patch application.
    case patch
    /// A notebook edit.
    case notebook
    /// An unclassified file mutation.
    case unknown
    /// A future file mutation kind preserved for fail-open decoding.
    case other(String)

    /// The raw wire identifier.
    public var rawValue: String {
        switch self {
        case .write: "write"
        case .edit: "edit"
        case .patch: "patch"
        case .notebook: "notebook"
        case .unknown: "unknown"
        case .other(let raw): raw
        }
    }

    /// Creates a file change kind from its raw wire identifier.
    /// - Parameter rawValue: The raw wire identifier.
    public init(rawValue: String) {
        switch rawValue {
        case "write": self = .write
        case "edit": self = .edit
        case "patch": self = .patch
        case "notebook": self = .notebook
        case "unknown": self = .unknown
        default: self = .other(rawValue)
        }
    }

    /// Decodes a fail-open file change kind.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the raw file change kind identifier.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
