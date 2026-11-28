/// A PostHog feature-flag value normalized by the cmux client-config API.
public enum ClientConfigFlagValue: Codable, Sendable, Equatable {
    /// A boolean flag value.
    case bool(Bool)
    /// A multivariate flag value.
    case variant(String)

    /// Decodes a flag value from either a JSON boolean or string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .variant(try container.decode(String.self))
        }
    }

    /// Encodes the flag value as the JSON scalar expected by `/api/client-config`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .variant(let value):
            try container.encode(value)
        }
    }

    /// The boolean value when this flag is boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The variant string when this flag is multivariate.
    public var variantValue: String? {
        if case .variant(let value) = self { return value }
        return nil
    }
}
