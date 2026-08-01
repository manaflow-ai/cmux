/// Identifies the implementation that owns a nested topology.
///
/// The raw value is intentionally open so a future provider can participate
/// without changing the identity representation used by existing clients.
public struct NestedProviderKind: Codable, Comparable, Hashable, Sendable {
    /// The Herdr nested multiplexer provider.
    public static let herdr = NestedProviderKind(rawValue: "herdr")

    /// Provider-defined opaque kind value.
    public let rawValue: String

    /// Creates a provider kind without interpreting its opaque value.
    ///
    /// Snapshot validation rejects empty, oversized, or control-bearing values.
    ///
    /// - Parameter rawValue: Provider kind token.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Orders provider kinds by their stable raw representation.
    ///
    /// - Parameters:
    ///   - lhs: Left provider kind.
    ///   - rhs: Right provider kind.
    /// - Returns: `true` when the left raw value sorts before the right value.
    public static func < (lhs: NestedProviderKind, rhs: NestedProviderKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Decodes a provider kind from its single string value.
    ///
    /// - Parameter decoder: Decoder containing the provider token.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    /// Encodes a provider kind as its single string value.
    ///
    /// - Parameter encoder: Encoder receiving the provider token.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
