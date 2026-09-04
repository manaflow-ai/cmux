import Foundation

/// A safe, persistence-friendly representation of one artifact's open target.
public enum ArtifactRepresentation: Codable, Equatable, Hashable, Sendable {
    /// A URL that can be handed to cmux's browser routing.
    case url(String)
    /// A path relative to the repository's managed payload directory.
    case managedFile(relativePath: String, suggestedFileName: String)
    /// A directory path that is revalidated before opening or dragging.
    case directory(path: String)
    /// Bounded inline text content.
    case inlineText(String)
    /// Bounded inline HTML content.
    case inlineHTML(String)

    private enum CodingKeys: String, CodingKey { case kind, value, suggestedFileName }

    /// Decodes legacy representations conservatively.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case "url": self = .url(value)
        case "managedFile":
            self = .managedFile(
                relativePath: value,
                suggestedFileName: try container.decodeIfPresent(String.self, forKey: .suggestedFileName) ?? "artifact"
            )
        case "directory": self = .directory(path: value)
        case "inlineHTML": self = .inlineHTML(value)
        default: self = .inlineText(value)
        }
    }

    /// Encodes a tagged representation to keep future migrations explicit.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .url(let value):
            try container.encode("url", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .managedFile(let relativePath, let suggestedFileName):
            try container.encode("managedFile", forKey: .kind)
            try container.encode(relativePath, forKey: .value)
            try container.encode(suggestedFileName, forKey: .suggestedFileName)
        case .directory(let path):
            try container.encode("directory", forKey: .kind)
            try container.encode(path, forKey: .value)
        case .inlineText(let value):
            try container.encode("inlineText", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .inlineHTML(let value):
            try container.encode("inlineHTML", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    /// Returns the text that is safe to expose to a copy or search operation.
    public var searchableValue: String {
        switch self {
        case .url(let value), .directory(let value), .inlineText(let value), .inlineHTML(let value): value
        case .managedFile(let relativePath, let suggestedFileName): "\(suggestedFileName) \(relativePath)"
        }
    }
}
