/// Identifies the implementation that owns a nested topology.
///
/// The raw value is intentionally open so a future provider can participate
/// without changing the identity representation used by existing clients.
public struct NestedProviderKind: Codable, Comparable, Hashable, Sendable {
    /// The Herdr nested multiplexer provider.
    public static let herdr = NestedProviderKind(rawValue: "herdr")

    /// Provider-defined opaque kind value preserved byte-for-byte on the wire.
    public let rawValue: String

    /// Creates a provider kind without interpreting its opaque value.
    ///
    /// Snapshot validation rejects empty, oversized, or control-bearing values.
    ///
    /// - Parameter rawValue: Provider kind token.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Compares provider tokens by their exact UTF-8 representation.
    public static func == (lhs: NestedProviderKind, rhs: NestedProviderKind) -> Bool {
        ExactUTF8String(lhs.rawValue) == ExactUTF8String(rhs.rawValue)
    }

    /// Hashes the exact UTF-8 provider token.
    ///
    /// - Parameter hasher: Hasher receiving the provider token.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ExactUTF8String(rawValue))
    }

    /// Orders provider kinds by their stable raw representation.
    ///
    /// - Parameters:
    ///   - lhs: Left provider kind.
    ///   - rhs: Right provider kind.
    /// - Returns: `true` when the left raw value sorts before the right value.
    public static func < (lhs: NestedProviderKind, rhs: NestedProviderKind) -> Bool {
        ExactUTF8String(lhs.rawValue) < ExactUTF8String(rhs.rawValue)
    }

    /// Decodes a provider kind from its byte-exact wire value.
    ///
    /// - Parameter decoder: Decoder containing the provider token.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(ExactUTF8String.self).value
    }

    /// Encodes a provider kind as a byte-exact wire value.
    ///
    /// - Parameter encoder: Encoder receiving the provider token.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ExactUTF8String(rawValue))
    }
}
