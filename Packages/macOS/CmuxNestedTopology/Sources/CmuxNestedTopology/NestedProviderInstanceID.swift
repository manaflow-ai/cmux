import Foundation

/// Opaque identity for one live provider process / connection generation.
///
/// Prefer a provider-issued server-lifetime UUID when available. Until then,
/// cmux assigns a random value per successful connection and never reuses it
/// across reconnects for mutation authority.
///
/// Public encoding is a single JSON string (not a keyed object).
public struct NestedProviderInstanceID: Hashable, Codable, Sendable, Comparable {
    /// Opaque provider-instance token. Never parsed by cmux.
    public let rawValue: String

    /// Creates a provider instance identifier.
    ///
    /// - Parameter rawValue: Opaque instance token. Empty values are rejected by
    ///   topology validation, not by this initializer.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fresh random instance identifier for a new cmux connection generation.
    public static func randomConnectionGeneration() -> NestedProviderInstanceID {
        NestedProviderInstanceID(rawValue: UUID().uuidString.lowercased())
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: NestedProviderInstanceID, rhs: NestedProviderInstanceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
