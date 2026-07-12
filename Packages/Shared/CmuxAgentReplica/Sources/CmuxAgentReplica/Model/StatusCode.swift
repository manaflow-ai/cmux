import Foundation

/// Identifies a status entry while preserving future status codes.
public enum StatusCode: Codable, Hashable, Sendable {
    /// Transcript context was compacted.
    case compacted
    /// The current turn was aborted.
    case turnAborted
    /// The agent reported an API error.
    case apiError
    /// Session metadata was observed.
    case sessionMeta
    /// A future status code preserved for fail-open decoding.
    case other(String)

    /// The raw wire identifier.
    public var rawValue: String {
        switch self {
        case .compacted: "compacted"
        case .turnAborted: "turn_aborted"
        case .apiError: "api_error"
        case .sessionMeta: "session_meta"
        case .other(let raw): raw
        }
    }

    /// Creates a status code from its raw wire identifier.
    /// - Parameter rawValue: The raw wire identifier.
    public init(rawValue: String) {
        switch rawValue {
        case "compacted": self = .compacted
        case "turn_aborted": self = .turnAborted
        case "api_error": self = .apiError
        case "session_meta": self = .sessionMeta
        default: self = .other(rawValue)
        }
    }

    /// Decodes a fail-open status code.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the raw status code identifier.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
