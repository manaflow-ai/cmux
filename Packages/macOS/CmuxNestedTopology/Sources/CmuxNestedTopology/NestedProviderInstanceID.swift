public import Foundation

/// Identifies one provider server within one connection generation.
///
/// `rawValue` may be a server-lifetime identifier supplied by the provider or
/// an adapter-generated value when the protocol lacks one. `generation` must
/// change whenever a new logical connection could make old actions unsafe.
public struct NestedProviderInstanceID: Codable, Hashable, Sendable {
    /// Provider or adapter supplied opaque instance value preserved byte-for-byte on the wire.
    public let rawValue: String

    /// Connection generation that invalidates stale nodes and actions.
    public let generation: UUID

    /// Creates a provider instance identity.
    ///
    /// - Parameters:
    ///   - rawValue: Opaque server instance value.
    ///   - generation: Unique logical connection generation.
    public init(rawValue: String, generation: UUID) {
        self.rawValue = rawValue
        self.generation = generation
    }

    /// Compares the generation and exact opaque provider-instance bytes.
    public static func == (
        lhs: NestedProviderInstanceID,
        rhs: NestedProviderInstanceID
    ) -> Bool {
        lhs.generation == rhs.generation
            && ExactUTF8String(lhs.rawValue) == ExactUTF8String(rhs.rawValue)
    }

    /// Hashes the generation and exact opaque provider-instance bytes.
    ///
    /// - Parameter hasher: Hasher receiving the identity components.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(generation)
        hasher.combine(ExactUTF8String(rawValue))
    }

    /// Decodes an instance identity while preserving opaque provider bytes.
    ///
    /// - Parameter decoder: Decoder containing the instance identity.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawValue = try container.decode(ExactUTF8String.self, forKey: .rawValue).value
        generation = try container.decode(UUID.self, forKey: .generation)
    }

    /// Encodes an instance identity with a byte-exact provider value.
    ///
    /// - Parameter encoder: Encoder receiving the instance identity.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ExactUTF8String(rawValue), forKey: .rawValue)
        try container.encode(generation, forKey: .generation)
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
        case generation
    }
}
